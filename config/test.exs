import Config

config :phoenix_kit_locations, ecto_repos: [PhoenixKitLocations.Test.Repo]

config :phoenix_kit_locations, PhoenixKitLocations.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_locations_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  priv: "test/support/postgres"

# Wire repo for library code that calls PhoenixKit.RepoHelper.repo()
config :phoenix_kit, repo: PhoenixKitLocations.Test.Repo

config :logger, level: :warning
