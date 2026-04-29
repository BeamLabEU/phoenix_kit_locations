defmodule PhoenixKitLocations.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by `PhoenixKitLocations.Paths` so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  phoenix_kit_settings table is unavailable, and admin paths always get
  the default locale ("en") prefix — so our base becomes
  `/en/admin/locations`.
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

  scope "/en/admin/locations", PhoenixKitLocations.Web do
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

      # Type CRUD
      live("/types/new", LocationTypeFormLive, :new)
      live("/types/:uuid/edit", LocationTypeFormLive, :edit)
    end
  end
end
