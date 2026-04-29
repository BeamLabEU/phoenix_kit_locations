defmodule PhoenixKitLocations.Web.LocationFormLive do
  @moduledoc "Create/edit form for locations with multilang, type toggles, and feature checkboxes."

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.Textarea

  alias PhoenixKitLocations.Errors
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Schemas.Location

  @translatable_fields ["name", "description", "public_notes"]
  @preserve_fields %{"status" => :status}

  # Feature keys are paired with a translatable label at render time via
  # `feature_label/1` — keeping the call site literal is what lets
  # `mix gettext.extract` (run in core) pick these up.
  @feature_keys ~w(
    wheelchair_accessible
    elevator
    parking
    public_transport
    loading_dock
    air_conditioning
    wifi
    restrooms
    security
    cctv
  )

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    case load_location(action, params) do
      {:not_found, uuid} ->
        Logger.info("Location not found for edit: #{uuid}")

        {:ok,
         socket
         |> put_flash(:error, Errors.message(:location_not_found))
         |> push_navigate(to: Paths.index())}

      {location, changeset, linked_type_uuids} ->
        {:ok,
         socket
         |> assign(
           page_title: page_title(action, location),
           action: action,
           location: location,
           all_types: safe_list_location_types(),
           linked_type_uuids: MapSet.new(linked_type_uuids),
           features: location.features || %{},
           feature_keys: @feature_keys,
           address_warning: nil
         )
         |> assign_form(changeset)
         |> mount_multilang()}
    end
  end

  defp load_location(:new, _params) do
    location = %Location{}
    {location, Locations.change_location(location), []}
  end

  defp load_location(:edit, params) do
    case Locations.get_location(params["uuid"]) do
      nil ->
        {:not_found, params["uuid"]}

      location ->
        {location, Locations.change_location(location), safe_linked_type_uuids(location)}
    end
  end

  defp safe_linked_type_uuids(location) do
    Locations.linked_type_uuids(location.uuid)
  rescue
    error ->
      Logger.error("Failed to load linked types for #{location.uuid}: #{inspect(error)}")
      []
  end

  defp safe_list_location_types do
    Locations.list_location_types(status: "active")
  rescue
    error ->
      Logger.error("Failed to load location types: #{inspect(error)}")
      []
  end

  defp page_title(:new, _location), do: gettext("New Location")

  defp page_title(:edit, location),
    do: gettext("Edit %{name}", name: location.name)

  # Keeps the `:changeset` assign (for `<.translatable_field>`) and `:form`
  # (for core `<.input>` / `<.select>` / `<.textarea>` which want a
  # `Phoenix.HTML.FormField` via `@form[:field]`) in sync.
  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, changeset: changeset, form: to_form(changeset, as: :location))
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"location" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    params = Map.put(params, "features", socket.assigns.features)

    changeset =
      socket.assigns.location
      |> Locations.change_location(params)
      |> Map.put(:action, :validate)

    {:noreply, socket |> assign_form(changeset) |> assign(:address_warning, nil)}
  end

  def handle_event("toggle_type", %{"uuid" => uuid}, socket) do
    linked = socket.assigns.linked_type_uuids

    linked =
      if MapSet.member?(linked, uuid),
        do: MapSet.delete(linked, uuid),
        else: MapSet.put(linked, uuid)

    {:noreply, assign(socket, :linked_type_uuids, linked)}
  end

  def handle_event("toggle_feature", %{"key" => key}, socket) do
    features = socket.assigns.features
    current = Map.get(features, key, false)
    features = Map.put(features, key, !current)
    {:noreply, assign(socket, :features, features)}
  end

  def handle_event("check_address", %{"location" => params}, socket) do
    exclude_uuid =
      if socket.assigns.action == :edit, do: socket.assigns.location.uuid, else: nil

    similar =
      Locations.find_similar_addresses(
        params["address_line_1"],
        params["city"],
        params["postal_code"],
        exclude_uuid
      )

    warning =
      if similar != [] do
        names = Enum.map_join(similar, ", ", & &1.name)
        gettext("Similar address found at: %{names}", names: names)
      end

    {:noreply, assign(socket, :address_warning, warning)}
  end

  def handle_event("save", %{"location" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    params = Map.put(params, "features", socket.assigns.features)

    save_location(socket, socket.assigns.action, params)
  end

  defp save_location(socket, :new, params) do
    case Locations.create_location(params, actor_opts(socket)) do
      {:ok, location} ->
        sync_types_and_redirect(socket, location.uuid, gettext("Location created."))

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save_location(socket, :edit, params) do
    case Locations.update_location(socket.assigns.location, params, actor_opts(socket)) do
      {:ok, location} ->
        sync_types_and_redirect(socket, location.uuid, gettext("Location updated."))

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  # Defensive catch-all for unmatched messages — e.g. future PubSub
  # broadcasts, multilang hook fall-throughs. Logs at :debug per the
  # workspace sync precedent at AGENTS.md:678-680.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[LocationFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp sync_types_and_redirect(socket, location_uuid, message) do
    type_uuids = MapSet.to_list(socket.assigns.linked_type_uuids)

    case Locations.sync_location_types(location_uuid, type_uuids, actor_opts(socket)) do
      {:ok, _sync_state} ->
        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: Paths.index())}

      {:error, _} ->
        Logger.error("Failed to sync location types for #{location_uuid}")

        {:noreply,
         socket
         |> put_flash(:warning, Errors.message(:type_assignment_failed))
         |> push_navigate(to: Paths.index())}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :lang_data,
        get_lang_data(assigns.changeset, assigns.current_lang, assigns.multilang_enabled)
      )

    ~H"""
    <div class="flex flex-col mx-auto max-w-2xl px-4 py-8 gap-6">
      <.admin_page_header
        back={Paths.index()}
        title={@page_title}
        subtitle={if @action == :new, do: gettext("Add a new location."), else: gettext("Update location details.")}
      />

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <%!-- PUBLIC INFORMATION                                     --%>
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <div class="card bg-base-100 shadow-lg">
          <%!-- Translatable fields (name, description, public notes) --%>
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            class="card-body pb-0 pt-4"
          />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="card-body pt-0 flex flex-col gap-5"
          >
            <:skeleton>
              <div class="form-control">
                <div class="label"><div class="skeleton h-4 w-14"></div></div>
                <div class="skeleton h-12 w-full rounded-lg"></div>
              </div>
              <div class="form-control">
                <div class="label"><div class="skeleton h-4 w-24"></div></div>
                <div class="skeleton h-20 w-full rounded-lg"></div>
              </div>
              <div class="form-control">
                <div class="label"><div class="skeleton h-4 w-20"></div></div>
                <div class="skeleton h-20 w-full rounded-lg"></div>
              </div>
            </:skeleton>
            <div class="card-body pt-0 flex flex-col gap-5">
              <.translatable_field
                field_name="name"
                form_prefix="location"
                changeset={@changeset}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={gettext("Name")}
                placeholder={gettext("e.g., Main Office, Downtown Showroom")}
                required
                class="w-full"
              />

              <.translatable_field
                field_name="description"
                form_prefix="location"
                changeset={@changeset}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={gettext("Description")}
                type="textarea"
                placeholder={gettext("Brief description of this location...")}
                class="w-full"
              />

              <.translatable_field
                field_name="public_notes"
                form_prefix="location"
                changeset={@changeset}
                schema_field={:public_notes}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={gettext("Public Notes")}
                type="textarea"
                placeholder={gettext("e.g., Bell is broken — knock loudly, entrance from side street...")}
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <div class="divider my-0"></div>

            <.section_heading icon="hero-map-pin">{gettext("Address")}</.section_heading>

            <div :if={@address_warning} class="alert alert-warning text-sm py-2">
              <.icon name="hero-exclamation-triangle" class="h-4 w-4 shrink-0" />
              <span>{@address_warning}</span>
            </div>

            <.input
              field={@form[:address_line_1]}
              type="text"
              label={gettext("Address Line 1")}
              placeholder={gettext("Street address, P.O. box")}
              phx-blur="check_address"
            />

            <.input
              field={@form[:address_line_2]}
              type="text"
              label={gettext("Address Line 2")}
              placeholder={gettext("Apartment, suite, unit, building, floor")}
            />

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input
                field={@form[:city]}
                type="text"
                label={gettext("City")}
                phx-blur="check_address"
              />
              <.input field={@form[:state]} type="text" label={gettext("State / Region")} />
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input
                field={@form[:postal_code]}
                type="text"
                label={gettext("Postal Code")}
                phx-blur="check_address"
              />
              <.input field={@form[:country]} type="text" label={gettext("Country")} />
            </div>

            <div class="divider my-0"></div>

            <.section_heading icon="hero-envelope">{gettext("Contact")}</.section_heading>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <.input
                field={@form[:phone]}
                type="tel"
                label={gettext("Phone")}
                placeholder={gettext("+1 234 567 890")}
              />
              <.input
                field={@form[:email]}
                type="email"
                label={gettext("Email")}
                placeholder={gettext("location@example.com")}
              />
              <.input
                field={@form[:website]}
                type="url"
                label={gettext("Website")}
                placeholder={gettext("https://...")}
              />
            </div>

            <div class="divider my-0"></div>

            <.section_heading icon="hero-check-circle">{gettext("Features & Amenities")}</.section_heading>

            <div class="grid grid-cols-2 md:grid-cols-3 gap-3">
              <label
                :for={key <- @feature_keys}
                class="flex items-center gap-2 cursor-pointer select-none"
                phx-click="toggle_feature"
                phx-value-key={key}
              >
                <input type="checkbox" class="checkbox checkbox-sm checkbox-primary" checked={Map.get(@features, key, false)} tabindex="-1" />
                <span class="label-text text-sm">{feature_label(key)}</span>
              </label>
            </div>
          </div>
        </div>

        <%!-- ═══════════════════════════════════════════════════════ --%>
        <%!-- INTERNAL                                               --%>
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <div class="card bg-base-100 shadow-lg mt-6">
          <div class="card-body flex flex-col gap-5">
            <.section_heading icon="hero-lock-closed">{gettext("Internal")}</.section_heading>
            <p class="text-sm text-base-content/50 -mt-3">
              {gettext("This information is only visible to administrators.")}
            </p>

            <.textarea
              field={@form[:notes]}
              label={gettext("Internal Notes")}
              rows="3"
              placeholder={gettext("Notes only visible to admins...")}
              class="min-h-[5rem]"
            />

            <.select
              field={@form[:status]}
              label={gettext("Status")}
              options={[{gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
              class="transition-colors focus-within:select-primary"
            />

            <%!-- Location types --%>
            <div :if={@all_types != []} class="flex flex-col gap-4">
              <div class="divider my-0"></div>

              <.section_heading icon="hero-tag">{gettext("Location Types")}</.section_heading>
              <p class="text-sm text-base-content/50 -mt-2">
                {gettext("Click to toggle. A location can have multiple types.")}
              </p>

              <div class="flex flex-wrap gap-2">
                <label
                  :for={t <- @all_types}
                  class={[
                    "badge badge-lg cursor-pointer gap-1.5 select-none transition-colors",
                    if(MapSet.member?(@linked_type_uuids, t.uuid),
                      do: "badge-primary",
                      else: "badge-ghost hover:badge-outline"
                    )
                  ]}
                  phx-click="toggle_type"
                  phx-value-uuid={t.uuid}
                >
                  <.icon
                    :if={MapSet.member?(@linked_type_uuids, t.uuid)}
                    name="hero-check"
                    class="h-3.5 w-3.5"
                  />
                  {t.name}
                </label>
              </div>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.link navigate={Paths.index()} class="btn btn-ghost">{gettext("Cancel")}</.link>
              <button
                type="submit"
                class="btn btn-primary phx-submit-loading:opacity-75"
                phx-disable-with={if @action == :new, do: gettext("Creating..."), else: gettext("Saving...")}
              >
                {if @action == :new, do: gettext("Create Location"), else: gettext("Save Changes")}
              </button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  # Small local component — keeps the five section headings in the
  # form template identical in shape (icon + label) without repeating
  # the `<h2>` chrome five times.
  attr(:icon, :string, required: true)
  slot(:inner_block, required: true)

  defp section_heading(assigns) do
    ~H"""
    <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
      <.icon name={@icon} class="h-4 w-4" />
      {render_slot(@inner_block)}
    </h2>
    """
  end

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  # Translatable feature labels. Each literal string is picked up by
  # `mix gettext.extract` (run in core). Falls back to the raw key so
  # unknown feature keys render *something* instead of crashing.
  defp feature_label("wheelchair_accessible"), do: gettext("Wheelchair Accessible")
  defp feature_label("elevator"), do: gettext("Elevator")
  defp feature_label("parking"), do: gettext("Parking")
  defp feature_label("public_transport"), do: gettext("Public Transport Nearby")
  defp feature_label("loading_dock"), do: gettext("Loading Dock")
  defp feature_label("air_conditioning"), do: gettext("Air Conditioning")
  defp feature_label("wifi"), do: gettext("Wi-Fi")
  defp feature_label("restrooms"), do: gettext("Restrooms")
  defp feature_label("security"), do: gettext("24/7 Security")
  defp feature_label("cctv"), do: gettext("CCTV")
  defp feature_label(key), do: key
end
