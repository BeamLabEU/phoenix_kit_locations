defmodule PhoenixKitLocations.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitLocations.Paths` so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  phoenix_kit_settings table is unavailable, and emits no locale segment on
  a single-language site (which the test environment is) — so our base is
  `/admin/locations`.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitLocations.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/admin/locations", PhoenixKitLocations.Web do
    pipe_through(:browser)

    live_session :locations_test,
      layout: {PhoenixKitLocations.Test.Layouts, :app},
      on_mount: {PhoenixKitLocations.Test.Hooks, :assign_scope} do
      # Locations + Types tabs share a single LiveView with two actions.
      live("/", LocationsLive, :index)
      live("/types", LocationsLive, :types)

      # Location CRUD
      live("/new", LocationFormLive, :new)
      live("/:uuid/edit", LocationFormLive, :edit)
      live("/:uuid/structure", LocationStructureLive, :edit)

      # Type CRUD
      live("/types/new", LocationTypeFormLive, :new)
      live("/types/:uuid/edit", LocationTypeFormLive, :edit)

      # Test-only host for `PlacePicker` LiveComponent events — no
      # real-UI equivalent, see `PlacePickerHarnessLive`.
      live("/__test__/place-picker", PlacePickerHarnessLive, :index)
    end
  end
end
