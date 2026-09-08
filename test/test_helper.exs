# Elixir 1.19's `mix test` no longer auto-loads modules from the
# `:elixirc_paths` test directories at test-helper time — only files
# matching `:test_load_filters` get loaded by the test runner. Our
# support modules (`PhoenixKitLocations.Test.Repo`, `Test.Endpoint`,
# etc.) are compiled but not loaded, so explicit `Code.require_file/2`
# calls are needed before `test_helper.exs` references them.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

# Check if the test database exists
db_name =
  Application.get_env(:phoenix_kit_locations, PhoenixKitLocations.Test.Repo)[:database] ||
    "phoenix_kit_locations_test"

# The preflight ships in core, and this module's core floor (`~> 2.0`)
# predates it — so it is used when the running core has it, and otherwise
# this falls through to exactly the previous behaviour.
db_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight) do
    # One classified connection attempt, with the repo's OWN credentials and
    # transport, before anything starts the pool.
    #
    # This replaces a `psql -lqt` listing. That check asked the wrong question:
    # it ran as the shell's user over a unix socket, so it reported "the
    # database is there" and said nothing about whether the CONFIGURED role
    # could reach it over TCP. When it could not, the answer arrived minutes
    # later as a pool checkout timeout that reads like a flaky test.
    case PhoenixKit.TestSupport.PostgresPreflight.check(
           Application.get_env(:phoenix_kit_locations, PhoenixKitLocations.Test.Repo, [])
         ) do
      :ok ->
        :exists

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)
        :not_found
    end
  else
    :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""
    \n⚠  Cannot reach test database "#{db_name}" — integration tests will be excluded.
       The reason is printed above.
    """)

    false
  else
    try do
      {:ok, _} = PhoenixKitLocations.Test.Repo.start_link()

      # Use core's `ensure_current/2` so the test schema tracks whatever
      # V-migrations core ships; no module-side DDL. See `PhoenixKit.Migration`
      # for re-runnable semantics. Accumulates rows in `schema_migrations`
      # between resets — cleared by `mix test.reset`.
      PhoenixKit.Migration.ensure_current(PhoenixKitLocations.Test.Repo, log: false)

      Ecto.Adapters.SQL.Sandbox.mode(PhoenixKitLocations.Test.Repo, :manual)
      true
    rescue
      e ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           The reason is printed above.
           Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""
        \n⚠  Could not connect to test database — integration tests will be excluded.
           The reason is printed above.
           Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_locations, :test_repo_available, repo_available)

# Exclude integration tests when DB is not available
exclude = if repo_available, do: [], else: [:integration]

# Force PhoenixKit's URL prefix cache to an empty string for tests so
# `Paths.index()` etc. produce paths the test router can match. Admin
# paths always get the default locale ("en") prefix, so our router
# scope is `/en/admin/locations`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint so Phoenix.LiveViewTest can drive our
# LiveViews via `live/2` with real URLs. Runs with `server: false`, so
# no port is opened. Only starts when the test DB is available —
# without DB, LiveView tests are excluded anyway and an endpoint start
# would fail on missing Phoenix/Plug deps in a DB-less smoke run.
if repo_available do
  {:ok, _} = PhoenixKitLocations.Test.Endpoint.start_link()
end

ExUnit.start(exclude: exclude)
