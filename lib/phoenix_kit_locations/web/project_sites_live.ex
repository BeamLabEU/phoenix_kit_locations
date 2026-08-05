defmodule PhoenixKitLocations.Web.ProjectSitesLive do
  @moduledoc """
  The Locations **Sites** tab for the `phoenix_kit_projects` hub — this
  module's `phoenix_kit_project_extensions/0` contribution (see that
  function in `PhoenixKitLocations`).

  Rendered by the projects hub via `live_render` with its embed-session
  contract; linkage is CONFIG-based (`location_uuids`, comma-separated in
  the project's Modules panel) — no FK, no dependency on the projects
  package. Read-only address cards with link-outs to the locations admin.

  Off-router-mountable: no `handle_params/3` (the hub's hard requirement).
  """

  use Phoenix.LiveView

  alias PhoenixKitLocations.{Locations, Paths}

  @impl true
  def mount(_params, session, socket) do
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
        <div class="card border border-dashed border-base-300 bg-base-100">
          <div class="card-body items-center text-center py-8 gap-2">
            <p class="text-sm opacity-70">
              <%= if @configured? do %>
                The configured locations no longer exist.
              <% else %>
                No sites linked to this project yet.
              <% end %>
            </p>
            <p class="text-xs opacity-50">
              Add location UUIDs (comma-separated) in the project's Modules &
              features panel — find them in
              <.link navigate={Paths.index()} class="link">Locations</.link>.
            </p>
          </div>
        </div>
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
                <.link navigate={Paths.location_edit(location.uuid)} class="btn btn-ghost btn-xs">
                  Open location
                </.link>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
