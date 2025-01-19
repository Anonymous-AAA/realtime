defmodule RealtimeWeb.TenantControllerTest do
  # async: false required due to the delete tests that connects to the database directly and might interfere with other tests
  use RealtimeWeb.ConnCase, async: false

  import Mock

  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Database
  alias Realtime.PromEx.Plugins.Tenants
  alias Realtime.Tenants
  alias Realtime.Tenants.Cache
  alias Realtime.Tenants.Connect
  alias Realtime.UsersCounter

  alias RealtimeWeb.ChannelsAuthorization
  alias RealtimeWeb.JwtVerification

  @update_attrs %{
    jwt_secret: "some updated jwt_secret",
    name: "some updated name",
    max_concurrent_users: 300,
    max_channels_per_client: 150,
    max_events_per_second: 250,
    max_joins_per_second: 50
  }

  @default_tenant_attrs %{
    "external_id" => "external_id",
    "name" => "localhost",
    "extensions" => [
      %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "db_host" => "127.0.0.1",
          "db_name" => "postgres",
          "db_user" => "supabase_admin",
          "db_password" => "postgres",
          "db_port" => "6432",
          "poll_interval" => 100,
          "poll_max_changes" => 100,
          "poll_max_record_bytes" => 1_048_576,
          "region" => "us-east-1"
        }
      }
    ],
    "postgres_cdc_default" => "postgres_cdc_rls",
    "jwt_secret" => "new secret"
  }

  @invalid_attrs %{external_id: nil, jwt_secret: nil, extensions: [], name: nil}

  setup %{conn: conn} do
    # Ensure no replication slot is present before the test
    Cleanup.ensure_no_replication_slot()

    Application.put_env(:realtime, :db_enc_key, "1234567890123456")

    new_conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header(
        "authorization",
        "Bearer auth_token"
      )

    on_exit(fn -> Realtime.Tenants.Connect.shutdown("dev_tenant") end)

    {:ok, conn: new_conn}
  end

  describe "show tenant" do
    test "removes db_password", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = get(conn, Routes.tenant_path(conn, :show, "dev_tenant"))
        response = json_response(conn, 200)

        refute get_in(response, ["data", "extensions", Access.at(0), "settings", "db_password"])
      end
    end
  end

  describe "create tenant" do
    test "renders tenant when data is valid", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        ext_id = @default_tenant_attrs["external_id"]
        conn = put(conn, Routes.tenant_path(conn, :update, ext_id), tenant: @default_tenant_attrs)
        assert %{"id" => _id, "external_id" => ^ext_id} = json_response(conn, 201)["data"]
        conn = get(conn, Routes.tenant_path(conn, :show, ext_id))
        assert ^ext_id = json_response(conn, 200)["data"]["external_id"]
        assert 200 = json_response(conn, 200)["data"]["max_concurrent_users"]
        assert 100 = json_response(conn, 200)["data"]["max_channels_per_client"]
        assert 100 = json_response(conn, 200)["data"]["max_events_per_second"]
        assert 100 = json_response(conn, 200)["data"]["max_joins_per_second"]
      end
    end

    test "encrypt creds", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        ext_id = @default_tenant_attrs["external_id"]
        conn = put(conn, Routes.tenant_path(conn, :update, ext_id), tenant: @default_tenant_attrs)
        [%{"settings" => settings}] = json_response(conn, 201)["data"]["extensions"]
        assert Crypto.encrypt!("127.0.0.1") == settings["db_host"]
        assert Crypto.encrypt!("postgres") == settings["db_name"]
        assert Crypto.encrypt!("supabase_admin") == settings["db_user"]
        refute settings["db_password"]

        %{extensions: [%{settings: settings}]} = Tenants.get_tenant_by_external_id("external_id")

        assert Crypto.encrypt!("postgres") == settings["db_password"]
      end
    end

    test "renders errors when data is invalid", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = post(conn, Routes.tenant_path(conn, :create), tenant: @invalid_attrs)
        assert json_response(conn, 422)["errors"] != %{}
      end
    end
  end

  describe "update tenant" do
    setup [:create_tenant]

    test "renders tenant when data is valid", %{
      conn: conn,
      tenant: %Tenant{id: id, external_id: ext_id} = _tenant
    } do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = put(conn, Routes.tenant_path(conn, :update, ext_id), tenant: @update_attrs)
        assert %{"id" => ^id, "external_id" => ^ext_id} = json_response(conn, 200)["data"]
        conn = get(conn, Routes.tenant_path(conn, :show, ext_id))
        assert "some updated name" = json_response(conn, 200)["data"]["name"]
        assert 300 = json_response(conn, 200)["data"]["max_concurrent_users"]
        assert 150 = json_response(conn, 200)["data"]["max_channels_per_client"]
        assert 250 = json_response(conn, 200)["data"]["max_events_per_second"]
        assert 50 = json_response(conn, 200)["data"]["max_joins_per_second"]
      end
    end

    test "renders errors when data is invalid", %{conn: conn, tenant: tenant} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn =
          put(conn, Routes.tenant_path(conn, :update, tenant.external_id), tenant: @invalid_attrs)

        assert json_response(conn, 422)["errors"] != %{}
      end
    end
  end

  describe "delete tenant" do
    setup [:create_tenant]

    setup %{tenant: tenant} do
      {:ok, _} = Realtime.Tenants.Connect.lookup_or_start_connection(tenant.external_id)
      :timer.sleep(1000)
      on_exit(fn -> Realtime.Tenants.Connect.shutdown(tenant.external_id) end)
      :ok
    end

    test "deletes chosen tenant", %{conn: conn, tenant: tenant} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        assert Cache.get_tenant_by_external_id(tenant.external_id)

        {:ok, db_conn} = Database.connect(tenant, "realtime_test")

        assert %{rows: [["realtime_messages_replication_slot_"]]} =
                 Postgrex.query!(db_conn, "SELECT slot_name FROM pg_replication_slots", [])

        conn = delete(conn, Routes.tenant_path(conn, :delete, tenant.external_id))
        assert response(conn, 204)

        :timer.sleep(5000)
        refute Cache.get_tenant_by_external_id(tenant.external_id)
        refute Tenants.get_tenant_by_external_id(tenant.external_id)

        assert {:ok, %{rows: []}} =
                 Postgrex.query(db_conn, "SELECT slot_name FROM pg_replication_slots", [])
      end
    end

    test "tenant doesn't exist", %{conn: conn} do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = delete(conn, Routes.tenant_path(conn, :delete, "wrong_external_id"))
        assert response(conn, 204)
      end
    end
  end

  describe "reload tenant" do
    setup [:create_tenant]

    test "reload when tenant does exist", %{conn: conn, tenant: tenant} do
      with_mock ChannelsAuthorization, authorize: fn _, _, _ -> {:ok, %{}} end do
        Routes.tenant_path(conn, :reload, tenant.external_id)
        %{status: status} = post(conn, Routes.tenant_path(conn, :reload, "wrong_external_id"))
        assert status == 404
      end
    end

    test "reload when tenant does not exist", %{conn: conn} do
      with_mock ChannelsAuthorization, authorize: fn _, _, _ -> {:ok, %{}} end do
        Routes.tenant_path(conn, :reload, "wrong_external_id")
        %{status: status} = post(conn, Routes.tenant_path(conn, :reload, "wrong_external_id"))
        assert status == 404
      end
    end
  end

  describe "health check tenant" do
    setup [:create_tenant]

    setup do
      Application.put_env(:realtime, :region, "us-east-1")
      on_exit(fn -> Application.put_env(:realtime, :region, nil) end)
    end

    test "health check when tenant does not exist", %{conn: conn} do
      with_mock ChannelsAuthorization, authorize: fn _, _, _ -> {:ok, %{}} end do
        Routes.tenant_path(conn, :reload, "wrong_external_id")
        %{status: status} = get(conn, Routes.tenant_path(conn, :health, "wrong_external_id"))
        assert status == 404
      end
    end

    test "healthy tenant with 0 client connections", %{
      conn: conn,
      tenant: %Tenant{external_id: ext_id}
    } do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        conn = get(conn, Routes.tenant_path(conn, :health, ext_id))
        data = json_response(conn, 200)["data"]

        assert %{
                 "healthy" => true,
                 "db_connected" => false,
                 "connected_cluster" => 0,
                 "region" => "us-east-1",
                 "node" => "nonode@nohost"
               } == data
      end
    end

    test "unhealthy tenant with 1 client connections", %{
      conn: conn,
      tenant: %Tenant{external_id: ext_id}
    } do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        # Fake adding a connected client here
        # No connection to the tenant database
        UsersCounter.add(self(), ext_id)

        conn = get(conn, Routes.tenant_path(conn, :health, ext_id))
        data = json_response(conn, 200)["data"]

        assert %{
                 "healthy" => false,
                 "db_connected" => false,
                 "connected_cluster" => 1,
                 "region" => "us-east-1",
                 "node" => "nonode@nohost"
               } == data
      end
    end

    test "healthy tenant with 1 client connection", %{
      conn: conn,
      tenant: %Tenant{external_id: ext_id}
    } do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        {:ok, db_conn} = Connect.lookup_or_start_connection(ext_id)
        # Fake adding a connected client here
        UsersCounter.add(self(), ext_id)

        # Fake a db connection
        :syn.register(Realtime.Tenants.Connect, ext_id, self(), %{conn: nil})

        :syn.update_registry(Realtime.Tenants.Connect, ext_id, fn _pid, meta ->
          %{meta | conn: db_conn}
        end)

        conn = get(conn, Routes.tenant_path(conn, :health, ext_id))
        data = json_response(conn, 200)["data"]

        assert %{
                 "healthy" => true,
                 "db_connected" => true,
                 "connected_cluster" => 1,
                 "region" => "us-east-1",
                 "node" => "nonode@nohost"
               } == data
      end
    end

    test "runs migrations", %{
      conn: conn,
      tenant: %Tenant{external_id: ext_id} = tenant
    } do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        {:ok, db_conn} = Database.connect(tenant, "realtime_test")

        Database.transaction(db_conn, fn transaction_conn ->
          Postgrex.query!(transaction_conn, "DROP SCHEMA realtime CASCADE", [])
          Postgrex.query!(transaction_conn, "CREATE SCHEMA realtime", [])
          Postgrex.query!(transaction_conn, "DROP ROLE supabase_realtime_admin", [])
        end)

        assert {:error, _} = Postgrex.query(db_conn, "SELECT * FROM realtime.messages", [])

        conn = get(conn, Routes.tenant_path(conn, :health, ext_id))
        data = json_response(conn, 200)["data"]
        :timer.sleep(2000)

        assert {:ok, %{rows: []}} = Postgrex.query(db_conn, "SELECT * FROM realtime.messages", [])

        assert %{"healthy" => true, "db_connected" => false, "connected_cluster" => 0} = data
      end
    end
  end

  describe "update tenant management information" do
    setup [:create_tenant]

    test "changes management information and returns updated values", %{
      conn: conn,
      tenant: tenant
    } do
      with_mock JwtVerification, verify: fn _token, _secret, _jwks -> {:ok, %{}} end do
        attrs = %{
          "max_concurrent_users" => 300,
          "max_channels_per_client" => 150,
          "max_events_per_second" => 250,
          "max_joins_per_second" => 50,
          "private_only" => true
        }

        conn = patch(conn, Routes.tenant_path(conn, :patch, tenant.external_id), attrs)
        data = json_response(conn, 200)["data"]
        assert data["max_concurrent_users"] == 300
        assert data["max_channels_per_client"] == 150
        assert data["max_events_per_second"] == 250
        assert data["max_joins_per_second"] == 50
        assert data["private_only"] == true

        tenant = Tenants.get_tenant_by_external_id(tenant.external_id)
        assert tenant.max_concurrent_users == 300
        assert tenant.max_channels_per_client == 150
        assert tenant.max_events_per_second == 250
        assert tenant.max_joins_per_second == 50
        assert tenant.private_only == true
      end
    end
  end

  defp create_tenant(_) do
    %{tenant: tenant_fixture(%{notify_private_alpha: true})}
  end
end
