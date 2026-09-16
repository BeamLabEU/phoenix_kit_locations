defmodule PhoenixKitLocations.Web.LocationsLive do
  @moduledoc """
  Landing page for the Locations module.

  Handles two actions via tabs:
  - `:index` — list of locations
  - `:types` — list of location types
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu
  import PhoenixKitLocations.Web.Components.OwnerComponents

  alias PhoenixKit.Users.Auth
  alias PhoenixKitLocations.Errors
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Policy

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: gettext_with_backend(PhoenixKitLocations.Gettext, "Locations"),
       locations: [],
       location_types: [],
       manage_all: false,
       owner_filter: :all,
       owner_emails: %{},
       confirm_delete: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = socket.assigns.live_action || :index
    manage_all? = Policy.manage_all?(socket.assigns[:phoenix_kit_current_scope])

    if action == :types and not manage_all? do
      # Types need `locations.manage_all`; the tab keeps the base key only
      # because this LiveView also serves the list (see `admin_tabs/0`).
      {:noreply,
       socket
       |> put_flash(:error, Errors.message(:not_allowed))
       |> push_navigate(to: Paths.index())}
    else
      socket =
        socket
        |> assign(:active_tab, action)
        |> assign_header(action)
        |> assign(:confirm_delete, nil)
        |> assign(:manage_all, manage_all?)
        |> assign(
          :owner_filter,
          if(manage_all?, do: parse_owner_filter(params["owner"]), else: :all)
        )
        |> load_data(action)

      {:noreply, socket}
    end
  end

  # The page title, trail and create button live in the PhoenixKit admin
  # header (`page_title` / `page_section` / `page_action`), not in the body.
  # Both actions share this LiveView, so a patch between them resets them all.
  defp assign_header(socket, :index) do
    assign(socket,
      page_title: gettext_with_backend(PhoenixKitLocations.Gettext, "Locations"),
      page_section: nil,
      page_section_path: nil,
      page_action: %{
        icon: "hero-plus",
        label: gettext_with_backend(PhoenixKitLocations.Gettext, "New Location"),
        navigate: Paths.location_new()
      }
    )
  end

  defp assign_header(socket, :types) do
    assign(socket,
      page_title: gettext_with_backend(PhoenixKitLocations.Gettext, "Types"),
      page_section: gettext_with_backend(PhoenixKitLocations.Gettext, "Locations"),
      page_section_path: Paths.index(),
      page_action: %{
        icon: "hero-plus",
        label: gettext_with_backend(PhoenixKitLocations.Gettext, "New Type"),
        navigate: Paths.type_new()
      }
    )
  end

  defp load_data(socket, :index) do
    # `Policy` pins a user without `manage_all` to their own locations; the
    # owner filter (always `:all` for them) only narrows a site-wide list.
    locations =
      Policy.list_locations(
        socket.assigns[:phoenix_kit_current_scope],
        owner_filter_opts(socket.assigns.owner_filter)
      )

    emails = if socket.assigns.manage_all, do: owner_emails(locations), else: %{}

    assign(socket, locations: locations, owner_emails: emails)
  rescue
    error ->
      Logger.error("Failed to load locations: #{inspect(error)}")

      put_flash(
        socket,
        :error,
        gettext("Failed to load locations.")
      )
  end

  defp load_data(socket, :types) do
    assign(socket, :location_types, Locations.list_location_types())
  rescue
    error ->
      Logger.error("Failed to load location types: #{inspect(error)}")

      put_flash(
        socket,
        :error,
        gettext("Failed to load location types.")
      )
  end

  # One batched user lookup for every owner on the page.
  defp owner_emails(locations) do
    locations
    |> Enum.map(& &1.owner_uuid)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Auth.get_users_by_uuids()
    |> Map.new(&{to_string(&1.uuid), &1.email})
  end

  # ── Event handlers ──────────────────────────────────────────────

  @impl true
  def handle_event("show_delete_confirm", %{"uuid" => uuid, "type" => type}, socket) do
    {:noreply, assign(socket, :confirm_delete, {type, uuid})}
  end

  def handle_event("delete_location", _params, socket) do
    case socket.assigns.confirm_delete do
      {"location", uuid} ->
        do_delete_location(socket, uuid)

      _ ->
        {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  def handle_event("delete_location_type", _params, socket) do
    case socket.assigns.confirm_delete do
      {"location_type", uuid} ->
        do_delete_location_type(socket, uuid)

      _ ->
        {:noreply, assign(socket, :confirm_delete, nil)}
    end
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  # Defensive catch-all for unmatched messages (e.g. future PubSub
  # broadcasts, MultilangForm hook fall-throughs). Logs at :debug per
  # the workspace sync precedent at AGENTS.md:678-680.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[LocationsLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp do_delete_location(socket, uuid), do: do_delete_item(socket, :location, uuid)

  defp do_delete_location_type(socket, uuid), do: do_delete_item(socket, :location_type, uuid)

  defp do_delete_item(socket, kind, uuid) do
    with %{} = record <- fetch_for_delete(kind, uuid, socket),
         {:ok, _} <- delete_for_kind(kind, record, socket) do
      {:noreply,
       socket
       |> put_flash(:info, deleted_message(kind))
       |> assign(:confirm_delete, nil)
       |> load_data(reload_action(kind))}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Errors.message(not_found_atom(kind)))
         |> assign(:confirm_delete, nil)
         |> load_data(reload_action(kind))}

      {:error, reason} ->
        Logger.error("Failed to delete #{kind} #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, Errors.message(delete_failed_atom(kind)))
         |> assign(:confirm_delete, nil)
         |> load_data(reload_action(kind))}
    end
  rescue
    error ->
      Logger.error("Unexpected error deleting #{kind} #{uuid}: #{inspect(error)}")

      {:noreply,
       socket
       |> put_flash(:error, Errors.message(:unexpected))
       |> assign(:confirm_delete, nil)}
  end

  # The uuid comes from the client: resolve it against the scope. A location
  # the user may not act on, or a type without `manage_all`, is a not-found.
  defp fetch_for_delete(:location, uuid, socket),
    do: Policy.get_location(socket.assigns[:phoenix_kit_current_scope], uuid)

  defp fetch_for_delete(:location_type, uuid, socket) do
    if Policy.manage_all?(socket.assigns[:phoenix_kit_current_scope]),
      do: Locations.get_location_type(uuid),
      else: nil
  end

  defp delete_for_kind(:location, record, socket) do
    Locations.delete_location(record, actor_opts(socket))
  end

  defp delete_for_kind(:location_type, record, socket) do
    Locations.delete_location_type(record, actor_opts(socket))
  end

  defp deleted_message(:location), do: gettext("Location deleted.")
  defp deleted_message(:location_type), do: gettext("Location type deleted.")

  defp not_found_atom(:location), do: :location_not_found
  defp not_found_atom(:location_type), do: :location_type_not_found

  defp delete_failed_atom(:location), do: :location_delete_failed
  defp delete_failed_atom(:location_type), do: :location_type_delete_failed

  defp reload_action(:location), do: :index
  defp reload_action(:location_type), do: :types

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col w-full px-4 py-6 gap-6">
      <%!-- Title, trail and the New Location / New Type button render in
           the PhoenixKit admin header (`assign_header/2`); Locations / Types
           switching lives in its subtab nav. --%>
      <%!-- Locations tab content --%>
      <div :if={@active_tab == :index} class="flex flex-col gap-4">
        <.owner_filter :if={@manage_all} active={@owner_filter} />
        <.locations_table locations={@locations} owner_emails={@owner_emails} manage_all={@manage_all} />
      </div>

      <%!-- Types tab content --%>
      <div :if={@active_tab == :types}>
        <.types_table location_types={@location_types} />
      </div>

      <.confirm_modal
        show={match?({"location", _}, @confirm_delete)}
        on_confirm="delete_location"
        on_cancel="cancel_delete"
        title={gettext("Delete Location")}
        title_icon="hero-trash"
        messages={[{:warning, gettext("This will permanently delete this location. This cannot be undone.")}]}
        confirm_text={gettext("Delete")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"location_type", _}, @confirm_delete)}
        on_confirm="delete_location_type"
        on_cancel="cancel_delete"
        title={gettext("Delete Location Type")}
        title_icon="hero-trash"
        messages={[{:warning, gettext("This will permanently delete this location type. Locations using it will lose the type association.")}]}
        confirm_text={gettext("Delete")}
        danger={true}
      />
    </div>
    """
  end

  defp locations_table(assigns) do
    ~H"""
    <div :if={@locations == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{gettext("No locations yet.")}</p>
      </div>
    </div>

    <div :if={@locations != []}>
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id="locations-list" items={@locations}
        card_fields={fn l -> [
          %{label: gettext("Address"), value: l.address_line_1 || "—"}
        ] ++ owner_card_field(l, @manage_all, @owner_emails) ++ [
          %{label: gettext("Types"), value: type_names(l)},
          %{label: gettext("Status"), value: status_label(l.status)}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Address")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("City")}</.table_default_header_cell>
            <.table_default_header_cell :if={@manage_all}>{owner_column_title()}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Type")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{gettext("Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={location <- @locations}>
            <.table_default_cell>
              <.link navigate={Paths.location_edit(location.uuid)} class="link link-hover font-medium">
                {location.name}
              </.link>
            </.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{location.address_line_1 || "—"}</.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{location.city || "—"}</.table_default_cell>
            <.table_default_cell :if={@manage_all} class="text-sm">
              <span class={if location.owner_uuid, do: "", else: "text-base-content/40"}>
                {owner_text(location.owner_uuid, @owner_emails)}
              </span>
            </.table_default_cell>
            <.table_default_cell>
              <div :if={location.location_types != []} class="flex flex-wrap gap-1">
                <span :for={t <- location.location_types} class="badge badge-sm badge-outline">{t.name}</span>
              </div>
              <span :if={location.location_types == []} class="text-base-content/40">—</span>
            </.table_default_cell>
            <.table_default_cell>
              <span class={["badge badge-sm", if(location.status == "active", do: "badge-success", else: "badge-ghost")]}>
                {status_label(location.status)}
              </span>
            </.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="dropdown" id={"loc-menu-#{location.uuid}"}>
                <.table_row_menu_link navigate={Paths.location_edit(location.uuid)} icon="hero-pencil" label={gettext("Edit")} />
                <.table_row_menu_link navigate={Paths.location_structure(location.uuid)} icon="hero-squares-2x2" label={gettext("Structure")} />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={location.uuid} phx-value-type="location" icon="hero-trash" label={gettext("Delete")} variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={location}>
          <.link navigate={Paths.location_edit(location.uuid)} class="font-medium text-sm link link-hover">{location.name}</.link>
        </:card_header>
        <:card_actions :let={location}>
          <.link navigate={Paths.location_edit(location.uuid)} class="btn btn-ghost btn-xs">{gettext("Edit")}</.link>
          <button phx-click="show_delete_confirm" phx-value-uuid={location.uuid} phx-value-type="location" class="btn btn-ghost btn-xs text-error">{gettext("Delete")}</button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end

  defp types_table(assigns) do
    ~H"""
    <div :if={@location_types == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{gettext("No location types yet.")}</p>
      </div>
    </div>

    <div :if={@location_types != []}>
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id="types-list" items={@location_types}
        card_fields={fn t -> [
          %{label: gettext("Description"), value: t.description || "—"},
          %{label: gettext("Status"), value: status_label(t.status)}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{gettext("Name")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Description")}</.table_default_header_cell>
            <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{gettext("Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={t <- @location_types}>
            <.table_default_cell>
              <.link navigate={Paths.type_edit(t.uuid)} class="link link-hover font-medium">
                {t.name}
              </.link>
            </.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{t.description || "—"}</.table_default_cell>
            <.table_default_cell>
              <span class={["badge badge-sm", if(t.status == "active", do: "badge-success", else: "badge-ghost")]}>
                {status_label(t.status)}
              </span>
            </.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="dropdown" id={"type-menu-#{t.uuid}"}>
                <.table_row_menu_link navigate={Paths.type_edit(t.uuid)} icon="hero-pencil" label={gettext("Edit")} />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={t.uuid} phx-value-type="location_type" icon="hero-trash" label={gettext("Delete")} variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={t}>
          <.link navigate={Paths.type_edit(t.uuid)} class="font-medium text-sm link link-hover">{t.name}</.link>
        </:card_header>
        <:card_actions :let={t}>
          <.link navigate={Paths.type_edit(t.uuid)} class="btn btn-ghost btn-xs">{gettext("Edit")}</.link>
          <button phx-click="show_delete_confirm" phx-value-uuid={t.uuid} phx-value-type="location_type" class="btn btn-ghost btn-xs text-error">{gettext("Delete")}</button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end

  defp type_names(%{location_types: types}) when is_list(types) and types != [] do
    Enum.map_join(types, ", ", & &1.name)
  end

  defp type_names(_), do: "—"

  # The owner card field only for a site-wide manager; a user scoped to their
  # own locations owns every row they see.
  defp owner_card_field(location, true, emails),
    do: [%{label: owner_column_title(), value: owner_text(location.owner_uuid, emails)}]

  defp owner_card_field(_location, _manage_all, _emails), do: []

  defp status_label("active"), do: gettext("Active")
  defp status_label("inactive"), do: gettext("Inactive")
  defp status_label(other), do: other
end
