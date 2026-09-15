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

    enable_locations()

    # Every conn starts as a site-wide locations admin (base +
    # `locations.manage_all`). Tests for location-scoped users replace it with
    # `put_test_scope(conn, fake_scope(permissions: ["locations"], ...))`.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{"phoenix_kit_test_scope" => fake_scope()})

    {:ok, conn: conn}
  end

  @doc """
  Turns the module on inside the test's sandbox. `Scope.can?/2` requires the
  base module to be enabled, so `locations.manage_all` is inert without it.
  Core's settings cache isn't started in this suite, so the write stays in the
  sandbox transaction.
  """
  def enable_locations do
    PhoenixKit.Settings.update_boolean_setting("locations_enabled", true)
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  Locations LVs read `socket.assigns[:phoenix_kit_current_scope]` for the
  user UUID (`actor_opts/1`, ownership) and, through
  `PhoenixKitLocations.Policy`, for `Scope.can?(scope, "locations.manage_all")`.
  (`cached_roles` is a list of role-name strings, per the workspace
  convention.)

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4
    * `:email` — defaults to a unique-suffix string
    * `:organization_uuid` — the organization account the user belongs to;
      defaults to `nil`
    * `:roles` — list of role-name strings; defaults to `["Owner"]`
    * `:permissions` — list of permission keys; defaults to
      `["locations", "locations.manage_all"]` (a site-wide admin). Pass
      `["locations"]` for a user scoped to their own locations.
    * `:authenticated?` — defaults to `true`

  ## Example

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _} = live(conn, "/en/admin/locations/")
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, ["Owner"])
    permissions = Keyword.get(opts, :permissions, ["locations", "locations.manage_all"])
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{
      uuid: user_uuid,
      email: email,
      organization_uuid: Keyword.get(opts, :organization_uuid)
    }

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

  @doc """
  Inserts a real `phoenix_kit_users` row, so `owner_uuid` foreign keys are
  satisfied. Goes through the schema rather than `Auth.register_user/1`, which
  needs core's rate-limiter process (not started in this suite) and a bcrypt
  round per call.
  """
  def fixture_user(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      email: "owner-#{n}@example.com",
      username: "owner_#{n}",
      hashed_password: "$2b$12$notarealhashjustenoughtosatisfythecolumn",
      is_active: true
    }

    TestRepo.insert!(struct(PhoenixKit.Users.Auth.User, Map.merge(defaults, attrs)))
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
