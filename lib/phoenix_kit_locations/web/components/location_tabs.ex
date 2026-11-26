defmodule PhoenixKitLocations.Web.Components.LocationTabs do
  @moduledoc """
  The one tab strip of a location's pages: Basics, Details, Structure and
  Settings.

  Basics, Details and Settings are panels of one form (`LocationFormLive`);
  Structure is its own LiveView (`LocationStructureLive`). On the form the
  three panels are event tabs (`on_change`), so switching keeps what was
  typed; on the Structure page they link back to the form opened on that
  panel (`Paths.location_edit/2`). Structure is always a link, and is left
  out for a location that has no uuid yet.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitLocations.Gettext

  import PhoenixKitWeb.Components.Core.NavTabs, only: [nav_tabs: 1]

  alias PhoenixKitLocations.Paths

  @form_tabs ~w(basics details settings)

  @doc "The ids of the tabs that are panels of the location form."
  @spec form_tabs() :: [String.t()]
  def form_tabs, do: @form_tabs

  attr(:location, :map, default: nil, doc: "the location; `nil` or unsaved hides Structure")
  attr(:active, :string, required: true, values: ~w(basics details structure settings))

  attr(:on_change, :string,
    default: nil,
    doc: "event for the form's panels; without it they link to the edit page"
  )

  # Rendering goes through core's <.nav_tabs>, so the strip shares the
  # ecosystem's tab markup. Paths.* URLs are already prefixed; nav_tabs
  # passes :navigate verbatim.
  def location_tabs(assigns) do
    uuid = assigns.location && assigns.location.uuid
    assigns = assign(assigns, :tabs, tabs(uuid, assigns.on_change))

    ~H"""
    <.nav_tabs
      id="location-tabs"
      variant={:border}
      class="mb-4"
      active_tab={@active}
      on_change={@on_change}
      tabs={@tabs}
    />
    """
  end

  defp tabs(uuid, on_change) do
    [
      form_tab("basics", gettext("Basics"), uuid, on_change),
      form_tab("details", gettext("Details"), uuid, on_change),
      uuid &&
        %{
          id: "structure",
          label: gettext("Structure"),
          navigate: Paths.location_structure(uuid)
        },
      form_tab("settings", gettext("Settings"), uuid, on_change)
    ]
    |> Enum.filter(& &1)
  end

  defp form_tab(id, label, _uuid, on_change) when is_binary(on_change),
    do: %{id: id, label: label}

  defp form_tab(id, label, uuid, nil),
    do: %{id: id, label: label, navigate: Paths.location_edit(uuid, id)}
end
