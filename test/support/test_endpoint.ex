defmodule PhoenixKitLocations.Test.Endpoint do
  @moduledoc """
  Minimal Phoenix.Endpoint used by the LiveView test suite.

  `phoenix_kit_locations` is a library — in production it borrows the
  host app's endpoint and router. For tests we spin up a tiny endpoint
  + router (`PhoenixKitLocations.Test.Router`) so `Phoenix.LiveViewTest`
  can drive our LiveViews through `live/2` with real URLs.
  """

  use Phoenix.Endpoint, otp_app: :phoenix_kit_locations

  @session_options [
    store: :cookie,
    key: "_phoenix_kit_locations_test_key",
    signing_salt: "locations-test-salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Session, @session_options)
  plug(PhoenixKitLocations.Test.Router)
end
