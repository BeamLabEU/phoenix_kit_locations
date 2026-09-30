defmodule PhoenixKitLocations.Web.ProjectSitesLive do
  @moduledoc """
  The Locations **Sites** tab for the `phoenix_kit_projects` hub — this
  module's `phoenix_kit_project_extensions/0` contribution (see that
  function in `PhoenixKitLocations`).

  Rendered by the projects hub via `live_render` with its embed-session
  contract; linkage is CONFIG-based (`location_uuids`, comma-separated in
  the project's Modules panel) — no FK, no dependency on the projects
  package. Read-only address cards with link-outs to the locations admin.

  Not owner-scoped: it shows every location the project config names to
  anyone the hub lets view the project, including locations owned by an
  account the viewer can't open under `/admin/locations`. The gate is who may
  edit the project's config.

  Off-router-mountable: no `handle_params/3` (the hub's hard requirement).
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitLocations.Gettext

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.EmptyState, only: [empty_state: 1]

  alias PhoenixKitLocations.{Locations, Paths}

  @impl true
  def mount(_params, session, socket) do
    put_embed_locale(session)

    uuids =
      session
      |> get_in(["config", "location_uuids"])
      |> parse_uuids()

    locations =
      uuids
      |> Enum.map(&safe_get/1)
      |> Enum.reject(&is_nil/1)

    {:ok, assign(socket, locations: locations, configured?: uuids != [])}
  end

  # A `live_render`ed LiveView runs in its own process, which does not inherit
  # the host's Gettext locale; the hub passes it as `session["locale"]`
  # (a content language such as "et" or "en-US" — the catalogue is keyed by
  # the base code).
  defp put_embed_locale(%{"locale" => locale}) when is_binary(locale) and locale != "" do
    base = locale |> String.split(["-", "_"]) |> hd() |> String.downcase()
    Gettext.put_locale(PhoenixKitLocations.Gettext, base)
  end

  defp put_embed_locale(_session), do: :ok

  defp parse_uuids(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(fn candidate -> match?({:ok, _}, Ecto.UUID.cast(candidate)) end)
  end

  defp parse_uuids(_), do: []

  # A locations DB hiccup or stale uuid degrades to a missing card — a
  # contributed extension tab must never crash the host project page.
  defp safe_get(uuid) do
    Locations.get_location(uuid)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <%= if @locations == [] do %>
        <.empty_state
          variant="card"
          icon="hero-map-pin"
          title={
            if @configured?,
              do: gettext("The configured locations no longer exist."),
              else: gettext("No sites linked to this project yet.")
          }
          description={
            gettext(
              "Add location UUIDs (comma-separated) in the project's Modules & features panel."
            )
          }
        >
          <.button variant="link" size="sm" navigate={Paths.index()}>
            {gettext("Find them in Locations")}
          </.button>
        </.empty_state>
      <% else %>
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div :for={location <- @locations} class="card border border-base-200 bg-base-100">
            <div class="card-body py-4 gap-1">
              <h3 class="font-semibold text-sm">{location.name}</h3>
              <p class="text-xs opacity-70">
                {[location.address_line_1, location.city, location.country]
                |> Enum.reject(&(&1 in [nil, ""]))
                |> Enum.join(", ")}
              </p>
              <div class="card-actions justify-end mt-1">
                <.button variant="ghost" size="xs" navigate={Paths.location_edit(location.uuid)}>
                  {gettext("Open location")}
                </.button>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
