defmodule PhoenixKitLocations.Web.PlacePickerHarnessLive do
  @moduledoc """
  Minimal host LiveView for `PlacePicker` LiveComponent tests.

  `PlacePicker` has no real production consumer yet — warehouse and
  manufacturing integration is on hold (see project memory) — so
  `place_picker_test.exs` needs *something* to mount it inside and
  receive its `{:place_picker_select, id, place}` message, the way
  `ItemPickerEventsTest` drives `ItemPicker` through the real
  `ItemFormLive` host. This is that host, purpose-built instead of
  borrowed, since no real consumer exists to reuse: it mounts exactly
  one `<.live_component>` and stashes the last-selected place on
  assigns so tests can assert on it via `render/1`/`element/2`.

  Not part of any real admin page — routed only from the test router,
  at `/en/admin/locations/__test__/place-picker`. Optionally accepts a
  `location_type_uuid` query param, forwarded straight to the picker's
  own `:location_type_uuid` attr, so tests can exercise the type
  filter without the harness needing any other state of its own.
  """

  use Phoenix.LiveView

  alias PhoenixKitLocations.Web.Components.PlacePicker

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     assign(socket,
       place: nil,
       location_type_uuid: params["location_type_uuid"],
       selected_space_uuid: params["selected_space_uuid"],
       owner_attrs: owner_attrs(params)
     )}
  end

  # `?owner_uuid=` forwards to the picker's `:owner_uuid` attr ("none" → nil,
  # "any" → :any). Without the param the attr is omitted entirely, which is
  # the picker's "no owner filter" case.
  defp owner_attrs(%{"owner_uuid" => "none"}), do: %{owner_uuid: nil}
  defp owner_attrs(%{"owner_uuid" => "any"}), do: %{owner_uuid: :any}
  defp owner_attrs(%{"owner_uuid" => owner_uuid}), do: %{owner_uuid: owner_uuid}
  defp owner_attrs(_params), do: %{}

  @impl true
  def handle_info({:place_picker_select, _id, place}, socket) do
    {:noreply, assign(socket, :place, place)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.live_component
        module={PlacePicker}
        id="harness-picker"
        location_type_uuid={@location_type_uuid}
        selected_space_uuid={@selected_space_uuid}
        {@owner_attrs}
      />

      <div :if={@place} id="selected-place">
        <span id="selected-location-uuid">{@place.location_uuid}</span>
        <span id="selected-space-uuid">{@place.space_uuid || "none"}</span>
      </div>
    </div>
    """
  end
end
