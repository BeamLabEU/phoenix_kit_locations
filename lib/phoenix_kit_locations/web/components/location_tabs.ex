defmodule PhoenixKitLocations.Web.Components.LocationTabs do
  @moduledoc """
  Shared tab navigation between a Location's "Details" and "Structure"
  pages. Each tab is served by a separate LiveView (`LocationFormLive`
  and `LocationStructureLive`), so tab links use `navigate` rather than
  `patch`, mirroring `PhoenixKitWarehouse.Web.Components.WarehouseHeader`.

  Only meant to be rendered once the Location already exists (has a
  `uuid`) — there is no Structure tab for a not-yet-created Location.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitLocations.Gettext

  import PhoenixKitWeb.Components.Core.NavTabs, only: [nav_tabs: 1]

  alias PhoenixKitLocations.Paths

  attr(:location, :map, required: true)
  attr(:active, :atom, required: true, values: [:details, :structure])

  # Rendering goes through core's <.nav_tabs> (border variant), so the
  # strip shares the ecosystem's tab markup instead of restating it; this
  # wrapper keeps only what is local — the tab list and the location.
  # Paths.* URLs are already prefixed; nav_tabs passes :navigate verbatim.
  def location_tabs(assigns) do
    ~H"""
    <.nav_tabs
      variant={:border}
      class="mb-4"
      active_tab={to_string(@active)}
      tabs={[
        %{id: "details", label: gettext("Details"), navigate: Paths.location_edit(@location.uuid)},
        %{
          id: "structure",
          label: gettext("Structure"),
          navigate: Paths.location_structure(@location.uuid)
        }
      ]}
    />
    """
  end
end
