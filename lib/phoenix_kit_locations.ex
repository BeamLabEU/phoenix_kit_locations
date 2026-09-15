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

  ## Ownership

  A location may belong to a `phoenix_kit_users` account (a person or an
  organization); without an owner it is global. Admins see and assign
  everything under `/admin/locations` (`locations.manage_all`); a user holding
  only the base `locations` permission sees and manages just their own
  locations on the same pages (`PhoenixKitLocations.Policy`). Tenant-facing code filters
  with `Locations.list_locations(owner_uuid: uuid)` and resolves single rows
  with `Locations.get_location_for_owner/2`.
  """

  use PhoenixKit.Module

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Settings

  @version Mix.Project.config()[:version]

  # ===========================================================================
  # Required callbacks
  # ===========================================================================

  @impl PhoenixKit.Module
  def module_key, do: "locations"

  @impl PhoenixKit.Module
  def module_name, do: "Locations"

  # Module-owned migration chain. Core's V135 baseline still CREATES the four
  # location tables on every install; V1 of this chain ADOPTS them (stamps the
  # `pkloc_schema:` marker without changing shape) and owns their future
  # evolution. The V2+ shape-change protocol is in the coordinator's moduledoc.
  @impl PhoenixKit.Module
  def migration_module, do: PhoenixKitLocations.Migrations

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
  def version, do: @version

  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_locations]

  # Project-extension contribution to the `phoenix_kit_projects` hub — the
  # duck-typed one-way contract (same shape as the dashboards widget
  # contract): its Extensions.Registry discovers this function; no
  # dependency on the projects package. The Sites tab links locations to a
  # project via per-instance CONFIG (comma-separated location uuids, set in
  # the project's Modules & features panel) — no FK.
  @doc false
  def phoenix_kit_project_extensions do
    [
      %{
        key: "locations_sites",
        name: "Sites",
        description: "Link physical locations to this project",
        icon: "hero-map-pin",
        module_key: "locations",
        default_enabled: false,
        tabs: [
          %{
            key: "sites",
            label: "Sites",
            icon: "hero-map-pin",
            lv: PhoenixKitLocations.Web.ProjectSitesLive
          }
        ],
        config_schema: [
          %{key: "location_uuids", type: :string, label: "Location UUIDs (comma-separated)"}
        ],
        permission_actions: [:view]
      }
    ]
  end

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: module_key(),
      label: "Locations",
      icon: "hero-map-pin",
      description:
        "Physical location management with custom types. The base permission covers only " <>
          "locations the user owns.",
      sub_permissions: [
        %{
          key: "manage_all",
          label: "Manage all locations",
          description:
            "Site-wide: every location (not just own), ownership, internal notes, attachments " <>
              "and the location Types pages"
        }
      ]
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
        gettext_backend: PhoenixKitLocations.Gettext,
        gettext_domain: "default",
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
        # Match the list page + its own sub-pages (new / edit) but NOT the
        # sibling `locations/types*` subtree. A bare `:prefix` would
        # swallow types; `:exact` misses /new and /:uuid/edit, leaving the
        # parent tab as the only visible "active" item on those pages.
        match: {:regex, ~r{(?:^|/)locations(?:/new|/[^/]+/edit)?$}},
        parent: :admin_locations,
        gettext_backend: PhoenixKitLocations.Gettext,
        gettext_domain: "default",
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
        # Types need `locations.manage_all`. Core maps each LiveView to ONE
        # permission key and `LocationsLive` also serves the list, so the
        # tab keeps the base key; `visible:` hides it and `LocationsLive` /
        # `LocationTypeFormLive` refuse it (the bookings settings pattern).
        visible: fn scope -> PhoenixKitLocations.Policy.manage_all?(scope) end,
        parent: :admin_locations,
        gettext_backend: PhoenixKitLocations.Gettext,
        gettext_domain: "default",
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
        gettext_backend: PhoenixKitLocations.Gettext,
        gettext_domain: "default",
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
        gettext_backend: PhoenixKitLocations.Gettext,
        gettext_domain: "default",
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
        gettext_backend: PhoenixKitLocations.Gettext,
        gettext_domain: "default",
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
        gettext_backend: PhoenixKitLocations.Gettext,
        gettext_domain: "default",
        live_view: {PhoenixKitLocations.Web.LocationFormLive, :edit}
      },
      %Tab{
        id: :admin_locations_structure,
        label: "Structure",
        icon: "hero-squares-2x2",
        path: "locations/:uuid/structure",
        priority: 677,
        level: :admin,
        permission: module_key(),
        parent: :admin_locations,
        visible: false,
        gettext_backend: PhoenixKitLocations.Gettext,
        gettext_domain: "default",
        live_view: {PhoenixKitLocations.Web.LocationStructureLive, :edit}
      }
    ]
  end

  # A user's locations cascade away with the user row (`owner_uuid` FK,
  # `ON DELETE CASCADE`). The cascade leaves no audit trail, so log each one
  # first. Core runs this best-effort and never lets it abort the deletion.
  @impl PhoenixKit.Module
  def before_user_delete(user_uuid) do
    PhoenixKitLocations.Locations.log_owner_deletion(user_uuid)
  end
end
