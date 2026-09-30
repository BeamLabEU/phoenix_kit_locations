defmodule PhoenixKitLocations.Web.Components.PlacePicker do
  @moduledoc """
  LiveComponent for picking a Location, and optionally a Space inside
  it, in one widget — a search-combobox for the Location half and the
  existing `SpaceTree` (read-only picker mode) for the Space half.

  Drop one into any LiveView. Each instance owns its own search/tree
  state; the parent only reacts to one message:

      {:place_picker_select, id, %{location_uuid: uuid, space_uuid: uuid_or_nil}}

  `space_uuid` is `nil` when the user picks "Use this location (no
  specific space)" instead of drilling into the tree. The tree stays
  open after a selection, so a consumer can immediately pick a
  different node without re-searching for the Location.

  ## Two halves

    * **Location** — core's `<.search_picker>`: its hook renders the
      dropdown client-side and asks this component for rows
      (`location_search` → a `"<id>:results"` push, one event name per
      instance so two pickers on a page never fill each other's list);
      a pick sends `select_location`. Locations are typically few, so
      filtering happens in Elixir over `Locations.list_locations/1`'s
      full result rather than a dedicated search function.
    * **Space** — once a Location is picked, its tree
      (`Spaces.list_tree/1`) renders through `SpaceTree.space_tree/1`
      with `show_actions={false}` — the same read-only mode built for
      this purpose. Selecting a node, or the "Use this location"
      button above the tree, sends the `:place_picker_select` message.

  ## Attrs

    * `:id` (required) — unique DOM/component id, echoed back in every
      `:place_picker_select` message.
    * `:location_type_uuid` — restricts the Location search to this
      type. Resolve the uuid yourself via
      `Locations.get_location_type_by_name/1` first — this component
      doesn't resolve type names itself, keeping its own API small.
      `nil` (default) searches every active Location.
    * `:selected_location_uuid`, `:selected_space_uuid` — optional,
      default `nil`. `:selected_space_uuid` seeds the tree's **initial**
      highlight (`space_tree/1`'s `selected_uuid`). The component's
      `update/2` applies these attrs only on first mount (seed-once
      semantics); from then on it tracks selection locally as the user
      picks nodes (clearing back to `nil` on `select_location` /
      `clear_location` / "Use this location"). A consumer can pass a
      static `selected_space_uuid` without having to echo every local
      update back — the seed is honored once and then the component
      manages the highlight itself. `:selected_location_uuid` is
      accepted for symmetry but not currently consumed — the Location
      half is always driven by the search-combobox in this version.
    * `:owner_uuid` — restricts the picker to one owner's locations, with
      `Locations.list_locations/1`'s meaning: a user uuid (that owner's
      locations), a list of uuids (any of them, e.g.
      `Policy.owner_uuids(@phoenix_kit_current_scope)` for a person and their
      organization), `nil` (global locations only) or `:any` (every owned
      location). **Omit the attr** to search every location. When given, it
      is enforced on selection too: a forged `select_location` for a
      location outside the filter is ignored. A picker shown to a tenant
      must always pass it.
    * `:locale` — when given, Location names (search results and the
      selected-location heading) show the translated name, same
      `_name`/`name` fallback chain as `Spaces.full_path/2`. `nil`
      (default) always shows the primary-language name. Space names
      inside the tree are not translated — `SpaceTree` itself doesn't
      support that (existing limitation, unrelated to this component).

  ## Usage

      type = Locations.get_location_type_by_name("Warehouse")

      <.live_component
        module={PhoenixKitLocations.Web.Components.PlacePicker}
        id="picker-1"
        location_type_uuid={type && type.uuid}
      />
  """

  use Phoenix.LiveComponent
  use Gettext, backend: PhoenixKitLocations.Gettext

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.SearchPicker, only: [search_picker: 1]
  import PhoenixKitLocations.Web.Components.SpaceTree, only: [space_tree: 1]

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitLocations.Spaces

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       query: "",
       matches: [],
       selected_location: nil,
       tree: [],
       expanded: MapSet.new(),
       location_type_uuid: nil,
       selected_location_uuid: nil,
       selected_space_uuid: nil,
       locale: nil,
       owner_filter: :none,
       initialized?: false
     )}
  end

  # Seed-once update: apply `selected_space_uuid`/`selected_location_uuid`
  # from parent attrs only on the first call (right after mount). On every
  # subsequent parent re-render, only non-seed attrs are updated so local
  # selection state set by `select_space`/`send_selection` is never clobbered.
  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:location_type_uuid, Map.get(assigns, :location_type_uuid))
      |> assign(:locale, Map.get(assigns, :locale))

    # `Map.fetch/2`: an omitted attr means "no owner filter", while an
    # explicit `nil` means "global locations only".
    socket =
      case Map.fetch(assigns, :owner_uuid) do
        {:ok, owner_uuid} -> assign(socket, :owner_filter, {:only, owner_uuid})
        :error -> socket
      end

    socket =
      if socket.assigns.initialized? do
        socket
      else
        socket
        |> assign(:selected_space_uuid, Map.get(assigns, :selected_space_uuid))
        |> assign(:selected_location_uuid, Map.get(assigns, :selected_location_uuid))
        |> assign(:initialized?, true)
      end

    {:ok, socket}
  end

  # ─────────────────────────────────────────────────────────────────
  # Events — Location search
  # ─────────────────────────────────────────────────────────────────

  # The SearchPicker hook asks for rows — on focus with an empty query too,
  # so the list is offered before any typing — and renders them itself.
  @impl true
  def handle_event("location_search", %{"q" => query}, socket) when is_binary(query) do
    socket = socket |> assign(:query, query) |> run_search()

    {:noreply,
     push_event(socket, results_event(socket.assigns.id), %{
       q: query,
       results: Enum.map(socket.assigns.matches, &location_row(&1, socket.assigns.locale)),
       has_more: false
     })}
  end

  def handle_event("select_location", %{"uuid" => uuid}, socket) do
    case selectable_location(uuid, socket.assigns.owner_filter) do
      nil ->
        {:noreply, socket}

      %Location{} = location ->
        tree = Spaces.list_tree(location.uuid)

        # Preserve a seeded `selected_space_uuid` when the newly-picked
        # Location is the one it belongs to (the seed's whole purpose —
        # see the moduledoc and `update/2`) instead of always clearing
        # it. Any other UUID (stale local selection from a previously
        # browsed Location) can't be in this Location's tree and is
        # correctly dropped.
        selected_space_uuid =
          if space_in_tree?(tree, socket.assigns.selected_space_uuid),
            do: socket.assigns.selected_space_uuid,
            else: nil

        {:noreply,
         socket
         |> assign(:selected_location, location)
         |> assign(:tree, tree)
         |> assign(:expanded, MapSet.new())
         |> assign(:selected_space_uuid, selected_space_uuid)
         |> assign(:query, "")
         |> assign(:matches, [])
         |> push_event(staged_event(socket.assigns.id), %{})}
    end
  end

  def handle_event("clear_location", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_location, nil)
     |> assign(:tree, [])
     |> assign(:expanded, MapSet.new())
     |> assign(:selected_space_uuid, nil)
     |> assign(:query, "")
     |> assign(:matches, [])}
  end

  # ─────────────────────────────────────────────────────────────────
  # Events — Space tree, read-only picker mode. Names match
  # `SpaceTree.space_tree/1`'s own event-name defaults — it targets
  # `@myself` for us, since we pass `myself={@myself}` below.
  # ─────────────────────────────────────────────────────────────────

  def handle_event("toggle_space_node", %{"uuid" => uuid}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, uuid),
        do: MapSet.delete(expanded, uuid),
        else: MapSet.put(expanded, uuid)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("select_space", %{"uuid" => uuid}, socket) do
    if space_in_tree?(socket.assigns.tree, uuid) do
      {:noreply, send_selection(socket, uuid)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_location_only", _params, socket) do
    {:noreply, send_selection(socket, nil)}
  end

  # ─────────────────────────────────────────────────────────────────
  # Search
  # ─────────────────────────────────────────────────────────────────

  defp run_search(socket) do
    matches =
      [status: "active", type_uuid: socket.assigns.location_type_uuid]
      |> put_owner_opt(socket.assigns.owner_filter)
      |> Locations.list_locations()
      |> filter_by_query(socket.assigns.query)

    assign(socket, :matches, matches)
  end

  # The event payload's uuid is client-supplied: resolve it and re-apply the
  # owner filter, so a forged `select_location` can't reach a location the
  # search would never have offered.
  defp selectable_location(uuid, owner_filter) do
    with {:ok, _} <- Ecto.UUID.cast(uuid),
         %Location{} = location <- Locations.get_location(uuid),
         true <- owner_allowed?(location, owner_filter) do
      location
    else
      _ -> nil
    end
  end

  defp put_owner_opt(opts, :none), do: opts
  defp put_owner_opt(opts, {:only, owner_uuid}), do: Keyword.put(opts, :owner_uuid, owner_uuid)

  # Same semantics as `Locations.list_locations/1`'s `owner_uuid:` option,
  # applied to one already-loaded row.
  defp owner_allowed?(_location, :none), do: true
  defp owner_allowed?(%Location{owner_uuid: owner}, {:only, nil}), do: is_nil(owner)
  defp owner_allowed?(%Location{owner_uuid: owner}, {:only, :any}), do: not is_nil(owner)

  defp owner_allowed?(%Location{owner_uuid: owner}, {:only, owner_uuids})
       when is_list(owner_uuids),
       do: not is_nil(owner) and owner in owner_uuids

  defp owner_allowed?(%Location{owner_uuid: owner}, {:only, owner_uuid}), do: owner == owner_uuid

  defp filter_by_query(locations, query) do
    case String.trim(query || "") do
      "" ->
        locations

      trimmed ->
        needle = String.downcase(trimmed)
        Enum.filter(locations, &String.contains?(String.downcase(&1.name), needle))
    end
  end

  # ─────────────────────────────────────────────────────────────────
  # Selection messaging
  # ─────────────────────────────────────────────────────────────────

  # Returns true when `uuid` is found anywhere in the nested tree list.
  # The tree is already scoped to `selected_location`, so any UUID found
  # here belongs to the current location — guards `select_space` against
  # stale / forged event payloads.
  defp space_in_tree?([], _uuid), do: false
  defp space_in_tree?([%{uuid: uuid} | _], uuid), do: true

  defp space_in_tree?([node | rest], uuid) do
    space_in_tree?(node.children, uuid) or space_in_tree?(rest, uuid)
  end

  # Notifies the parent and mirrors the pick into local state so the
  # tree's highlight (`selected_uuid={@selected_space_uuid}`) updates
  # immediately — the caller doesn't have to echo the attr back in.
  #
  # `select_space`/`select_location_only` only render once a Location
  # is selected, so a normal click can't reach here with
  # `selected_location: nil` — this clause guards a stale queued event
  # racing a `clear_location` click instead (mirrors `ItemPicker`'s own
  # `select` handler no-op-ing on an unresolvable uuid).
  defp send_selection(
         %{assigns: %{selected_location: %Location{} = location}} = socket,
         space_uuid
       ) do
    send(
      self(),
      {:place_picker_select, socket.assigns.id,
       %{location_uuid: location.uuid, space_uuid: space_uuid}}
    )

    assign(socket, :selected_space_uuid, space_uuid)
  end

  defp send_selection(socket, _space_uuid), do: socket

  # ─────────────────────────────────────────────────────────────────
  # Display helpers
  # ─────────────────────────────────────────────────────────────────

  defp location_display_name(%Location{name: name}, nil), do: name

  defp location_display_name(%Location{data: data, name: name}, locale) do
    translation = Multilang.get_language_data(data, locale)
    Map.get(translation, "_name") || Map.get(translation, "name") || name
  end

  # Per-instance push names: `push_event` reaches every hook listening on a
  # name, so a shared one would fill every picker on the page.
  defp results_event(id), do: "#{id}:results"
  defp staged_event(id), do: "#{id}:staged"

  defp location_row(%Location{} = location, locale) do
    row = %{
      kind: "location",
      uuid: location.uuid,
      label: location_display_name(location, locale),
      icon: "hero-map-pin"
    }

    case location_subtitle(location) do
      "" -> row
      subtitle -> Map.put(row, :sublabel, subtitle)
    end
  end

  defp location_subtitle(%Location{address_line_1: line1, city: city}) do
    [line1, city]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  # ─────────────────────────────────────────────────────────────────
  # Render
  # ─────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="relative w-full">
      <div class="flex flex-col gap-2">
        <div :if={@selected_location} class="flex items-center justify-between gap-2">
          <span class="text-sm font-medium truncate flex items-center gap-1">
            <.icon name="hero-map-pin" class="w-4 h-4 shrink-0 text-base-content/50" />
            {location_display_name(@selected_location, @locale)}
          </span>
          <.button
            type="button"
            variant="ghost"
            size="xs"
            phx-click="clear_location"
            phx-target={@myself}
          >
            {gettext("Change")}
          </.button>
        </div>

        <.button
          :if={@selected_location}
          type="button"
          variant="ghost"
          size="sm"
          class="justify-start"
          phx-click="select_location_only"
          phx-target={@myself}
        >
          <.icon name="hero-check" class="w-4 h-4 mr-1" />
          {gettext("Use this location (no specific space)")}
        </.button>

        <.space_tree
          :if={@selected_location}
          tree={@tree}
          expanded={@expanded}
          selected_uuid={@selected_space_uuid}
          myself={@myself}
          show_actions={false}
        />

        <.search_picker
          :if={!@selected_location}
          id={"#{@id}-input"}
          dropdown_id={"#{@id}-listbox"}
          search_event="location_search"
          results_event={results_event(@id)}
          pick_event="select_location"
          staged_event={staged_event(@id)}
          search_on_focus
          placeholder={gettext("Search locations…")}
          class="input input-sm w-full"
          searching_label={gettext("Searching…")}
          more_label={gettext("Load more")}
          loading_more_label={gettext("Loading…")}
          no_matches_label={gettext("No locations found")}
        />
      </div>
    </div>
    """
  end
end
