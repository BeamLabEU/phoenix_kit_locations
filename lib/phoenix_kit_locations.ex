defmodule PhoenixKitLocations do
  @moduledoc """
  Locations module for PhoenixKit.

  Manages physical locations (offices, showrooms, warehouses, etc.) with
  user-defined location types. Each location has a name, address, contact
  info, and an optional type that categorizes what kind of location it is.

  ## Installation

  Add to your parent app's `mix.exs`:

      {:phoenix_kit_locations, path: "../phoenix_kit_locations"}

  Then `mix deps.get`. The module auto-discovers via beam scanning.
  Enable it in Admin > Modules.

  ## Structure

  - **Location Types** — user-created categories (e.g., "Showroom", "Storage", "Office")
  - **Locations** — physical places with name, address, contact info, and an assigned type
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def module_key, do: "locations"

  @impl PhoenixKit.Module
  def module_name, do: "Locations"

  @impl PhoenixKit.Module
  def enabled? do
    Settings.get_boolean_setting("locations_enabled", false)
  rescue
    _ -> false
  catch
    # Sandbox owner exits on test teardown — would surface as a 1-in-N
    # flake otherwise. See workspace AGENTS.md:911 for the precedent.
    :exit, _ -> false
  end

  @impl PhoenixKit.Module
  def enable_system do
    result = Settings.update_boolean_setting_with_module("locations_enabled", true, module_key())
    PhoenixKitLocations.Locations.log_module_toggle(:enabled)
    result
  end

  @impl PhoenixKit.Module
  def disable_system do
    result = Settings.update_boolean_setting_with_module("locations_enabled", false, module_key())
    PhoenixKitLocations.Locations.log_module_toggle(:disabled)
    result
  end

  # ===========================================================================
  # Optional callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def version, do: "0.1.1"

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_locations]

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Locations",
      icon: "hero-map-pin",
      description: "Physical location management with custom types"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      # Main tab — parent container, redirects to first subtab.
      %Tab{
        id: :admin_locations,
        label: "Locations",
        icon: "hero-map-pin",
        path: "locations",
        priority: 670,
        level: :admin,
        permission: module_key(),
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        redirect_to_first_subtab: true,
        live_view: {PhoenixKitLocations.Web.LocationsLive, :index}
      },
      # Subtabs — Locations, Types
      %Tab{
        id: :admin_locations_list,
        label: "Locations",
        icon: "hero-map-pin",
        path: "locations",
        priority: 671,
        level: :admin,
        permission: module_key(),
        match: :exact,
        parent: :admin_locations,
        live_view: {PhoenixKitLocations.Web.LocationsLive, :index}
      },
      %Tab{
        id: :admin_locations_types,
        label: "Types",
        icon: "hero-tag",
        path: "locations/types",
        priority: 672,
        level: :admin,
        permission: module_key(),
        parent: :admin_locations,
        live_view: {PhoenixKitLocations.Web.LocationsLive, :types}
      },
      # Static paths MUST come before wildcard :uuid paths

      # Location — static paths
      %Tab{
        id: :admin_locations_new,
        label: "New Location",
        icon: "hero-plus",
        path: "locations/new",
        priority: 673,
        level: :admin,
        permission: module_key(),
        parent: :admin_locations,
        visible: false,
        live_view: {PhoenixKitLocations.Web.LocationFormLive, :new}
      },
      # Types — static paths
      %Tab{
        id: :admin_locations_type_new,
        label: "New Type",
        icon: "hero-plus",
        path: "locations/types/new",
        priority: 674,
        level: :admin,
        permission: module_key(),
        parent: :admin_locations,
        visible: false,
        live_view: {PhoenixKitLocations.Web.LocationTypeFormLive, :new}
      },
      %Tab{
        id: :admin_locations_type_edit,
        label: "Edit Type",
        icon: "hero-pencil-square",
        path: "locations/types/:uuid/edit",
        priority: 675,
        level: :admin,
        permission: module_key(),
        parent: :admin_locations,
        visible: false,
        live_view: {PhoenixKitLocations.Web.LocationTypeFormLive, :edit}
      },
      # Wildcard :uuid routes LAST
      %Tab{
        id: :admin_locations_edit,
        label: "Edit Location",
        icon: "hero-pencil-square",
        path: "locations/:uuid/edit",
        priority: 676,
        level: :admin,
        permission: module_key(),
        parent: :admin_locations,
        visible: false,
        live_view: {PhoenixKitLocations.Web.LocationFormLive, :edit}
      }
    ]
  end
end
