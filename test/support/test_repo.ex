defmodule PhoenixKitLocations.Test.Repo do
  use Ecto.Repo,
    otp_app: :phoenix_kit_locations,
    adapter: Ecto.Adapters.Postgres
end
