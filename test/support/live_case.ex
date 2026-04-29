defmodule PhoenixKitLocations.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available, matching the rest of
  the suite.

  ## Example

      defmodule PhoenixKitLocations.Web.LocationFormLiveTest do
        use PhoenixKitLocations.LiveCase

        test "renders", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/en/admin/locations/new")
          assert html =~ "New Location"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitLocations.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitLocations.ActivityLogAssertions
      import PhoenixKitLocations.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitLocations.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  Locations LVs read `socket.assigns[:phoenix_kit_current_scope]` only
  to thread the user UUID into `actor_opts/1`. They do not call
  `Scope.admin?/1` or `has_module_access?/2`, so the role/permission
  fields are present but unused here. (Per workspace AGENTS.md:1175,
  `cached_roles` must be a list of role-name strings if `admin?/1`
  ever gets called — locations doesn't, but we follow the convention.)

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role-name strings; defaults to `["Owner"]`
    * `:permissions` — list of module-key strings; defaults to `["locations"]`
    * `:authenticated?` — defaults to `true`

  ## Example

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _} = live(conn, "/en/admin/locations/")
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, ["Owner"])
    permissions = Keyword.get(opts, :permissions, ["locations"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  Plugs a fake scope into the test conn's session so the
  `:assign_scope` `on_mount` hook can put it on socket assigns at
  mount time. Pair with `fake_scope/1`.
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end

  @doc "Creates a LocationType fixture with a unique name."
  def fixture_location_type(attrs \\ %{}) do
    {:ok, type} =
      PhoenixKitLocations.Locations.create_location_type(
        Map.merge(%{name: "Type #{System.unique_integer([:positive])}"}, attrs)
      )

    type
  end

  @doc "Creates a Location fixture with a unique name."
  def fixture_location(attrs \\ %{}) do
    {:ok, location} =
      PhoenixKitLocations.Locations.create_location(
        Map.merge(%{name: "Location #{System.unique_integer([:positive])}"}, attrs)
      )

    location
  end
end
