defmodule PhoenixKitLocations.Web.LocationsLive do
  @moduledoc """
  Landing page for the Locations module.

  Handles two actions via tabs:
  - `:index` — list of locations
  - `:types` — list of location types
  """

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: Gettext.gettext(PhoenixKitWeb.Gettext, "Locations"),
       locations: [],
       location_types: [],
       confirm_delete: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    action = socket.assigns.live_action || :index

    socket =
      socket
      |> assign(:active_tab, action)
      |> assign(:page_title, tab_title(action))
      |> assign(:confirm_delete, nil)
      |> load_data(action)

    {:noreply, socket}
  end

  defp tab_title(:index), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Locations")
  defp tab_title(:types), do: Gettext.gettext(PhoenixKitWeb.Gettext, "Location Types")

  defp load_data(socket, :index) do
    assign(socket, :locations, Locations.list_locations())
  rescue
    error ->
      Logger.error("Failed to load locations: #{inspect(error)}")

      put_flash(
        socket,
        :error,
        Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to load locations.")
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
        Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to load location types.")
      )
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

  defp do_delete_location(socket, uuid) do
    with %{} = location <- Locations.get_location(uuid),
         {:ok, _} <- Locations.delete_location(location) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Location deleted."))
       |> assign(:confirm_delete, nil)
       |> load_data(:index)}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Location not found."))
         |> assign(:confirm_delete, nil)
         |> load_data(:index)}

      {:error, reason} ->
        Logger.error("Failed to delete location #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete location.")
         )
         |> assign(:confirm_delete, nil)
         |> load_data(:index)}
    end
  rescue
    error ->
      Logger.error("Unexpected error deleting location: #{inspect(error)}")

      {:noreply,
       socket
       |> put_flash(
         :error,
         Gettext.gettext(PhoenixKitWeb.Gettext, "An unexpected error occurred.")
       )
       |> assign(:confirm_delete, nil)}
  end

  defp do_delete_location_type(socket, uuid) do
    with %{} = location_type <- Locations.get_location_type(uuid),
         {:ok, _} <- Locations.delete_location_type(location_type) do
      {:noreply,
       socket
       |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Location type deleted."))
       |> assign(:confirm_delete, nil)
       |> load_data(:types)}
    else
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Location type not found."))
         |> assign(:confirm_delete, nil)
         |> load_data(:types)}

      {:error, reason} ->
        Logger.error("Failed to delete location type #{uuid}: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Failed to delete location type.")
         )
         |> assign(:confirm_delete, nil)
         |> load_data(:types)}
    end
  rescue
    error ->
      Logger.error("Unexpected error deleting location type: #{inspect(error)}")

      {:noreply,
       socket
       |> put_flash(
         :error,
         Gettext.gettext(PhoenixKitWeb.Gettext, "An unexpected error occurred.")
       )
       |> assign(:confirm_delete, nil)}
  end

  # ── Render ──────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-5xl px-4 py-6 gap-6">
      <%!-- Tab navigation --%>
      <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div role="tablist" class="tabs tabs-bordered">
          <.link
            patch={Paths.index()}
            class={["tab", @active_tab == :index && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Locations")}
          </.link>
          <.link
            patch={Paths.types()}
            class={["tab", @active_tab == :types && "tab-active"]}
          >
            {Gettext.gettext(PhoenixKitWeb.Gettext, "Types")}
          </.link>
        </div>

        <div class="self-end sm:self-auto">
          <.link :if={@active_tab == :index} navigate={Paths.location_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "New Location")}
          </.link>
          <.link :if={@active_tab == :types} navigate={Paths.type_new()} class="btn btn-primary btn-sm">
            {Gettext.gettext(PhoenixKitWeb.Gettext, "New Type")}
          </.link>
        </div>
      </div>

      <%!-- Locations tab content --%>
      <div :if={@active_tab == :index}>
        <.locations_table locations={@locations} />
      </div>

      <%!-- Types tab content --%>
      <div :if={@active_tab == :types}>
        <.types_table location_types={@location_types} />
      </div>

      <.confirm_modal
        show={match?({"location", _}, @confirm_delete)}
        on_confirm="delete_location"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Location")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitWeb.Gettext, "This will permanently delete this location. This cannot be undone.")}]}
        confirm_text={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
        danger={true}
      />

      <.confirm_modal
        show={match?({"location_type", _}, @confirm_delete)}
        on_confirm="delete_location_type"
        on_cancel="cancel_delete"
        title={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete Location Type")}
        title_icon="hero-trash"
        messages={[{:warning, Gettext.gettext(PhoenixKitWeb.Gettext, "This will permanently delete this location type. Locations using it will lose the type association.")}]}
        confirm_text={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
        danger={true}
      />
    </div>
    """
  end

  defp locations_table(assigns) do
    ~H"""
    <div :if={@locations == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{Gettext.gettext(PhoenixKitWeb.Gettext, "No locations yet.")}</p>
      </div>
    </div>

    <div :if={@locations != []}>
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id="locations-list" items={@locations}
        card_fields={fn l -> [
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Address"), value: l.address_line_1 || "—"},
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Types"), value: type_names(l)},
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Status"), value: String.capitalize(l.status)}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Address")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "City")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Type")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={location <- @locations}>
            <.table_default_cell class="font-medium">{location.name}</.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{location.address_line_1 || "—"}</.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{location.city || "—"}</.table_default_cell>
            <.table_default_cell>
              <div :if={location.location_types != []} class="flex flex-wrap gap-1">
                <span :for={t <- location.location_types} class="badge badge-sm badge-outline">{t.name}</span>
              </div>
              <span :if={location.location_types == []} class="text-base-content/40">—</span>
            </.table_default_cell>
            <.table_default_cell>
              <span class={["badge badge-sm", if(location.status == "active", do: "badge-success", else: "badge-ghost")]}>
                {String.capitalize(location.status)}
              </span>
            </.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="dropdown" id={"loc-menu-#{location.uuid}"}>
                <.table_row_menu_link navigate={Paths.location_edit(location.uuid)} icon="hero-pencil" label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")} />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={location.uuid} phx-value-type="location" icon="hero-trash" label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")} variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={location}>
          <.link navigate={Paths.location_edit(location.uuid)} class="font-medium text-sm link link-hover">{location.name}</.link>
        </:card_header>
        <:card_actions :let={location}>
          <.link navigate={Paths.location_edit(location.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}</.link>
          <button phx-click="show_delete_confirm" phx-value-uuid={location.uuid} phx-value-type="location" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}</button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end

  defp types_table(assigns) do
    ~H"""
    <div :if={@location_types == []} class="card bg-base-100 shadow">
      <div class="card-body items-center text-center py-12">
        <p class="text-base-content/60">{Gettext.gettext(PhoenixKitWeb.Gettext, "No location types yet.")}</p>
      </div>
    </div>

    <div :if={@location_types != []}>
      <.table_default
        variant="zebra" size="sm" toggleable={true}
        id="types-list" items={@location_types}
        card_fields={fn t -> [
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Description"), value: t.description || "—"},
          %{label: Gettext.gettext(PhoenixKitWeb.Gettext, "Status"), value: String.capitalize(t.status)}
        ] end}
      >
        <.table_default_header>
          <.table_default_row>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Description")}</.table_default_header_cell>
            <.table_default_header_cell>{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</.table_default_header_cell>
            <.table_default_header_cell class="text-right whitespace-nowrap">{Gettext.gettext(PhoenixKitWeb.Gettext, "Actions")}</.table_default_header_cell>
          </.table_default_row>
        </.table_default_header>
        <.table_default_body>
          <.table_default_row :for={t <- @location_types}>
            <.table_default_cell class="font-medium">{t.name}</.table_default_cell>
            <.table_default_cell class="text-sm text-base-content/60">{t.description || "—"}</.table_default_cell>
            <.table_default_cell>
              <span class={["badge badge-sm", if(t.status == "active", do: "badge-success", else: "badge-ghost")]}>
                {String.capitalize(t.status)}
              </span>
            </.table_default_cell>
            <.table_default_cell class="text-right whitespace-nowrap">
              <.table_row_menu mode="dropdown" id={"type-menu-#{t.uuid}"}>
                <.table_row_menu_link navigate={Paths.type_edit(t.uuid)} icon="hero-pencil" label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")} />
                <.table_row_menu_divider />
                <.table_row_menu_button phx-click="show_delete_confirm" phx-value-uuid={t.uuid} phx-value-type="location_type" icon="hero-trash" label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")} variant="error" />
              </.table_row_menu>
            </.table_default_cell>
          </.table_default_row>
        </.table_default_body>
        <:card_header :let={t}>
          <.link navigate={Paths.type_edit(t.uuid)} class="font-medium text-sm link link-hover">{t.name}</.link>
        </:card_header>
        <:card_actions :let={t}>
          <.link navigate={Paths.type_edit(t.uuid)} class="btn btn-ghost btn-xs">{Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}</.link>
          <button phx-click="show_delete_confirm" phx-value-uuid={t.uuid} phx-value-type="location_type" class="btn btn-ghost btn-xs text-error">{Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}</button>
        </:card_actions>
      </.table_default>
    </div>
    """
  end

  defp type_names(%{location_types: types}) when is_list(types) and types != [] do
    Enum.map_join(types, ", ", & &1.name)
  end

  defp type_names(_), do: "—"
end
