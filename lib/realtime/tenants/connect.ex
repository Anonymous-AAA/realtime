defmodule Realtime.Tenants.Connect do
  @moduledoc """
  This module is responsible for attempting to connect to a tenant's database and store the DBConnection in a Syn registry.

  ## Options
  * `:check_connected_user_interval` - The interval in milliseconds to check if there are any connected users to a tenant channel. If there are no connected users, the connection will be stopped.
  * `:erpc_timeout` - The timeout in milliseconds for the `:erpc` calls to the tenant's database.
  """
  use GenServer, restart: :transient

  require Logger

  import Realtime.Logs

  alias Realtime.Api.Tenant
  alias Realtime.Rpc
  alias Realtime.Tenants
  alias Realtime.Tenants.ReplicationConnection
  alias Realtime.Tenants.Connect.CheckConnection
  alias Realtime.Tenants.Connect.GetTenant
  alias Realtime.Tenants.Connect.Piper
  alias Realtime.Tenants.Connect.RegisterProcess
  alias Realtime.Tenants.Connect.StartCounters
  alias Realtime.Tenants.Listen
  alias Realtime.Tenants.Migrations
  alias Realtime.UsersCounter

  @rpc_timeout_default 30_000
  @check_connected_user_interval_default 50_000
  @connected_users_bucket_shutdown [0, 0, 0, 0, 0, 0]

  defstruct tenant_id: nil,
            db_conn_reference: nil,
            db_conn_pid: nil,
            broadcast_changes_pid: nil,
            listen_pid: nil,
            check_connected_user_interval: nil,
            connected_users_bucket: [1]

  @doc """
  Returns the database connection for a tenant. If the tenant is not connected, it will attempt to connect to the tenant's database.
  """
  @spec lookup_or_start_connection(binary(), keyword()) ::
          {:ok, pid()}
          | {:error, :tenant_database_unavailable}
          | {:error, :initializing}
          | {:error, :tenant_database_connection_initializing}
          | {:error, :rpc_error, term()}
  def lookup_or_start_connection(tenant_id, opts \\ []) when is_binary(tenant_id) do
    case get_status(tenant_id) do
      {:ok, conn} ->
        {:ok, conn}

      {:error, :tenant_database_unavailable} ->
        call_external_node(tenant_id, opts)

      {:error, :tenant_database_connection_initializing} ->
        Process.sleep(100)
        call_external_node(tenant_id, opts)

      {:error, :initializing} ->
        {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Returns the database connection pid from :syn if it exists.
  """
  @spec get_status(binary()) ::
          {:ok, pid()}
          | {:error, :tenant_database_unavailable}
          | {:error, :initializing}
          | {:error, :tenant_database_connection_initializing}
  def get_status(tenant_id) do
    case :syn.lookup(__MODULE__, tenant_id) do
      {_, %{conn: nil}} ->
        {:error, :initializing}

      {_, %{conn: conn}} ->
        {:ok, conn}

      :undefined ->
        Logger.warning("Connection process starting up")
        {:error, :tenant_database_connection_initializing}

      error ->
        log_error("SynInitializationError", error)
        {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Connects to a tenant's database and stores the DBConnection in the process :syn metadata
  """
  @spec connect(binary(), keyword()) :: {:ok, DBConnection.t()} | {:error, term()}
  def connect(tenant_id, opts \\ []) do
    supervisor =
      {:via, PartitionSupervisor, {Realtime.Tenants.Connect.DynamicSupervisor, tenant_id}}

    spec = {__MODULE__, [tenant_id: tenant_id] ++ opts}

    case DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, _} ->
        get_status(tenant_id)

      {:error, {:already_started, _}} ->
        get_status(tenant_id)

      {:error, {:shutdown, :tenant_db_too_many_connections}} ->
        {:error, :tenant_db_too_many_connections}

      {:error, {:shutdown, :tenant_not_found}} ->
        {:error, :tenant_not_found}

      {:error, :shutdown} ->
        log_error("UnableToConnectToTenantDatabase", "Unable to connect to tenant database")
        {:error, :tenant_database_unavailable}

      {:error, error} ->
        log_error("UnableToConnectToTenantDatabase", error)
        {:error, :tenant_database_unavailable}
    end
  end

  @doc """
  Returns the pid of the tenant Connection process
  """
  @spec whereis(binary()) :: pid | nil
  def whereis(tenant_id) do
    case :syn.lookup(__MODULE__, tenant_id) do
      {pid, _} -> pid
      :undefined -> nil
    end
  end

  @doc """
  Shutdown the tenant Connection and linked processes
  """
  @spec shutdown(binary()) :: :ok | nil
  def shutdown(tenant_id) do
    case whereis(tenant_id) do
      pid when is_pid(pid) -> GenServer.stop(pid)
      _ -> :ok
    end
  end

  def start_link(opts) do
    tenant_id = Keyword.get(opts, :tenant_id)

    check_connected_user_interval =
      Keyword.get(opts, :check_connected_user_interval, @check_connected_user_interval_default)

    name = {__MODULE__, tenant_id, %{conn: nil}}

    state = %__MODULE__{
      tenant_id: tenant_id,
      check_connected_user_interval: check_connected_user_interval
    }

    opts = Keyword.put(opts, :name, {:via, :syn, name})

    GenServer.start_link(__MODULE__, state, opts)
  end

  ## GenServer callbacks
  # Needs to be done on init/1 to guarantee the GenServer only starts if we are able to connect to the database
  @impl GenServer
  def init(%{tenant_id: tenant_id} = state) do
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    pipes = [
      GetTenant,
      CheckConnection,
      StartCounters,
      RegisterProcess
    ]

    case Piper.run(pipes, state) do
      {:ok, acc} ->
        {:ok, acc, {:continue, :run_migrations}}

      {:error, :tenant_not_found} ->
        {:stop, {:shutdown, :tenant_not_found}}

      {:error, :tenant_db_too_many_connections} ->
        {:stop, {:shutdown, :tenant_db_too_many_connections}}

      {:error, error} ->
        log_error("UnableToConnectToTenantDatabase", error)
        {:stop, :shutdown}
    end
  end

  def handle_continue(:run_migrations, state) do
    %{tenant: tenant, db_conn_pid: db_conn_pid} = state

    with :ok <- Migrations.run_migrations(tenant),
         :ok <- Migrations.create_partitions(db_conn_pid) do
      {:noreply, state, {:continue, :start_listen_and_replication}}
    else
      error ->
        log_error("MigrationsFailedToRun", error)
        {:stop, :shutdown, state}
    end
  rescue
    error ->
      log_error("MigrationsFailedToRun", error)
      {:stop, :shutdown, state}
  end

  def handle_continue(:start_listen_and_replication, state) do
    %{tenant: tenant} = state

    with {:ok, broadcast_changes_pid} <- ReplicationConnection.start(tenant, self()),
         {:ok, listen_pid} <- Listen.start(tenant, self()) do
      {:noreply, %{state | broadcast_changes_pid: broadcast_changes_pid, listen_pid: listen_pid},
       {:continue, :setup_connected_user_events}}
    else
      {:error, :max_wal_senders_reached} ->
        log_error("ReplicationMaxWalSendersReached", "Tenant database has reached the maximum number of WAL senders")
        {:stop, :shutdown, state}

      {:error, error} ->
        log_error("StartListenAndReplicationFailed", error)
        {:stop, :shutdown, state}
    end
  rescue
    error ->
      log_error("StartListenAndReplicationFailed", error)
      {:stop, :shutdown, state}
  end

  @impl true
  def handle_continue(:setup_connected_user_events, state) do
    %{
      check_connected_user_interval: check_connected_user_interval,
      connected_users_bucket: connected_users_bucket,
      tenant_id: tenant_id
    } = state

    :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:operations:" <> tenant_id)
    send_connected_user_check_message(connected_users_bucket, check_connected_user_interval)
    :ets.insert(__MODULE__, {tenant_id})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        :check_connected_users,
        %{
          tenant_id: tenant_id,
          check_connected_user_interval: check_connected_user_interval,
          connected_users_bucket: connected_users_bucket
        } = state
      ) do
    connected_users_bucket =
      tenant_id
      |> update_connected_users_bucket(connected_users_bucket)
      |> send_connected_user_check_message(check_connected_user_interval)

    {:noreply, %{state | connected_users_bucket: connected_users_bucket}}
  end

  def handle_info(:shutdown, state) do
    %{
      db_conn_pid: db_conn_pid,
      broadcast_changes_pid: broadcast_changes_pid,
      listen_pid: listen_pid
    } = state

    Logger.info("Tenant has no connected users, database connection will be terminated")
    :ok = GenServer.stop(db_conn_pid, :normal, 500)

    broadcast_changes_pid && Process.alive?(broadcast_changes_pid) &&
      GenServer.stop(broadcast_changes_pid, :normal, 500)

    listen_pid && Process.alive?(listen_pid) &&
      GenServer.stop(listen_pid, :normal, 500)

    {:stop, :normal, state}
  end

  def handle_info(:suspend_tenant, state) do
    %{
      db_conn_pid: db_conn_pid,
      broadcast_changes_pid: broadcast_changes_pid,
      listen_pid: listen_pid
    } = state

    Logger.warning("Tenant was suspended, database connection will be terminated")
    :ok = GenServer.stop(db_conn_pid, :normal, 500)

    broadcast_changes_pid && Process.alive?(broadcast_changes_pid) &&
      GenServer.stop(broadcast_changes_pid, :normal, 500)

    listen_pid && Process.alive?(listen_pid) &&
      GenServer.stop(listen_pid, :normal, 500)

    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, db_conn_reference, _, _, _},
        %{db_conn_reference: db_conn_reference} = state
      ) do
    Logger.info("Database connection has been terminated")
    {:stop, :normal, state}
  end

  # Ignore messages to avoid handle_info unmatched functions
  def handle_info(_, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{tenant_id: tenant_id}) do
    Logger.info("Tenant #{tenant_id} has been terminated: #{inspect(reason)}")
    Realtime.MetricsCleaner.delete_metric(tenant_id)
    :ok
  end

  ## Private functions
  defp call_external_node(tenant_id, opts) do
    rpc_timeout = Keyword.get(opts, :rpc_timeout, @rpc_timeout_default)

    with tenant <- Tenants.Cache.get_tenant_by_external_id(tenant_id),
         :ok <- tenant_suspended?(tenant),
         {:ok, node} <- Realtime.Nodes.get_node_for_tenant(tenant) do
      Rpc.enhanced_call(node, __MODULE__, :connect, [tenant_id, opts], timeout: rpc_timeout, tenant: tenant_id)
    end
  end

  defp update_connected_users_bucket(tenant_id, connected_users_bucket) do
    connected_users_bucket
    |> then(&(&1 ++ [UsersCounter.tenant_users(tenant_id)]))
    |> Enum.take(-6)
  end

  defp send_connected_user_check_message(
         @connected_users_bucket_shutdown,
         check_connected_user_interval
       ) do
    Process.send_after(self(), :shutdown, check_connected_user_interval)
  end

  defp send_connected_user_check_message(connected_users_bucket, check_connected_user_interval) do
    Process.send_after(self(), :check_connected_users, check_connected_user_interval)
    connected_users_bucket
  end

  defp tenant_suspended?(%Tenant{suspend: true}), do: {:error, :tenant_suspended}
  defp tenant_suspended?(_), do: :ok
end
