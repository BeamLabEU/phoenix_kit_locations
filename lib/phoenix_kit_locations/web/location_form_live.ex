defmodule PhoenixKitLocations.Web.LocationFormLive do
  @moduledoc "Create/edit form for locations with multilang, type toggles, and feature checkboxes."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Schemas.Location

  @translatable_fields ["name", "description", "public_notes"]
  @preserve_fields %{"status" => :status}

  @feature_keys [
    {"wheelchair_accessible", "Wheelchair Accessible"},
    {"elevator", "Elevator"},
    {"parking", "Parking"},
    {"public_transport", "Public Transport Nearby"},
    {"loading_dock", "Loading Dock"},
    {"air_conditioning", "Air Conditioning"},
    {"wifi", "Wi-Fi"},
    {"restrooms", "Restrooms"},
    {"security", "24/7 Security"},
    {"cctv", "CCTV"}
  ]

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {location, changeset, linked_type_uuids} =
      case action do
        :new ->
          l = %Location{}
          {l, Locations.change_location(l), []}

        :edit ->
          case Locations.get_location(params["uuid"]) do
            nil ->
              Logger.warning("Location not found for edit: #{params["uuid"]}")
              {nil, nil, []}

            l ->
              linked =
                try do
                  Locations.linked_type_uuids(l.uuid)
                rescue
                  error ->
                    Logger.error("Failed to load linked types for #{l.uuid}: #{inspect(error)}")
                    []
                end

              {l, Locations.change_location(l), linked}
          end
      end

    if is_nil(location) and action == :edit do
      {:ok,
       socket
       |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Location not found."))
       |> push_navigate(to: Paths.index())}
    else
      all_types =
        try do
          Locations.list_location_types(status: "active")
        rescue
          error ->
            Logger.error("Failed to load location types: #{inspect(error)}")
            []
        end

      features = (location && location.features) || %{}

      {:ok,
       socket
       |> assign(
         page_title:
           if(action == :new,
             do: Gettext.gettext(PhoenixKitWeb.Gettext, "New Location"),
             else: Gettext.gettext(PhoenixKitWeb.Gettext, "Edit %{name}", name: location.name)
           ),
         action: action,
         location: location,
         changeset: changeset,
         all_types: all_types,
         linked_type_uuids: MapSet.new(linked_type_uuids),
         features: features,
         feature_keys: @feature_keys,
         address_warning: nil
       )
       |> mount_multilang()}
    end
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
      |> Map.put(:action, socket.assigns.changeset.action)

    {:noreply, assign(socket, changeset: changeset, address_warning: nil)}
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
      try do
        Locations.find_similar_addresses(
          params["address_line_1"],
          params["city"],
          params["postal_code"],
          exclude_uuid
        )
      rescue
        error ->
          Logger.error("Address check failed: #{inspect(error)}")
          []
      end

    warning =
      if similar != [] do
        names = Enum.map_join(similar, ", ", & &1.name)
        Gettext.gettext(PhoenixKitWeb.Gettext, "Similar address found at: %{names}", names: names)
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
    case Locations.create_location(params) do
      {:ok, location} ->
        sync_types_and_redirect(
          socket,
          location.uuid,
          Gettext.gettext(PhoenixKitWeb.Gettext, "Location created.")
        )

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_location(socket, :edit, params) do
    case Locations.update_location(socket.assigns.location, params) do
      {:ok, location} ->
        sync_types_and_redirect(
          socket,
          location.uuid,
          Gettext.gettext(PhoenixKitWeb.Gettext, "Location updated.")
        )

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp sync_types_and_redirect(socket, location_uuid, message) do
    type_uuids = MapSet.to_list(socket.assigns.linked_type_uuids)

    case Locations.sync_location_types(location_uuid, type_uuids) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: Paths.index())}

      {:error, _} ->
        Logger.error("Failed to sync location types for #{location_uuid}")

        {:noreply,
         socket
         |> put_flash(
           :warning,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Saved but failed to update type assignments.")
         )
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
        subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Add a new location."), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Update location details.")}
      />

      <.form for={to_form(@changeset)} action="#" phx-change="validate" phx-submit="save">
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
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "e.g., Main Office, Downtown Showroom")}
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
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Description")}
                type="textarea"
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Brief description of this location...")}
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
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Public Notes")}
                type="textarea"
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "e.g., Bell is broken — knock loudly, entrance from side street...")}
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <div class="divider my-0"></div>

            <%!-- Address --%>
            <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z" />
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z" />
              </svg>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Address")}
            </h2>

            <div :if={@address_warning} class="alert alert-warning text-sm py-2">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-2.5L13.732 4c-.77-.833-1.964-.833-2.732 0L4.082 16.5c-.77.833.192 2.5 1.732 2.5z" />
              </svg>
              <span>{@address_warning}</span>
            </div>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Address Line 1")}</span>
              <input type="text" name="location[address_line_1]" value={Ecto.Changeset.get_field(@changeset, :address_line_1) || ""} class="input input-bordered w-full transition-colors focus:input-primary" placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Street address, P.O. box")} phx-blur="check_address" />
            </div>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Address Line 2")}</span>
              <input type="text" name="location[address_line_2]" value={Ecto.Changeset.get_field(@changeset, :address_line_2) || ""} class="input input-bordered w-full transition-colors focus:input-primary" placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Apartment, suite, unit, building, floor")} />
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-control">
                <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "City")}</span>
                <input type="text" name="location[city]" value={Ecto.Changeset.get_field(@changeset, :city) || ""} class="input input-bordered w-full transition-colors focus:input-primary" phx-blur="check_address" />
              </div>
              <div class="form-control">
                <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "State / Region")}</span>
                <input type="text" name="location[state]" value={Ecto.Changeset.get_field(@changeset, :state) || ""} class="input input-bordered w-full transition-colors focus:input-primary" />
              </div>
            </div>

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <div class="form-control">
                <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Postal Code")}</span>
                <input type="text" name="location[postal_code]" value={Ecto.Changeset.get_field(@changeset, :postal_code) || ""} class="input input-bordered w-full transition-colors focus:input-primary" phx-blur="check_address" />
              </div>
              <div class="form-control">
                <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Country")}</span>
                <input type="text" name="location[country]" value={Ecto.Changeset.get_field(@changeset, :country) || ""} class="input input-bordered w-full transition-colors focus:input-primary" />
              </div>
            </div>

            <div class="divider my-0"></div>

            <%!-- Contact --%>
            <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z" />
              </svg>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Contact")}
            </h2>

            <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
              <div class="form-control">
                <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Phone")}</span>
                <input type="tel" name="location[phone]" value={Ecto.Changeset.get_field(@changeset, :phone) || ""} class="input input-bordered w-full transition-colors focus:input-primary" placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "+1 234 567 890")} />
              </div>
              <div class="form-control">
                <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Email")}</span>
                <input type="email" name="location[email]" value={Ecto.Changeset.get_field(@changeset, :email) || ""} class="input input-bordered w-full transition-colors focus:input-primary" placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "location@example.com")} />
                <p :for={msg <- changeset_errors(@changeset, :email)} class="text-error text-sm mt-1">{msg}</p>
              </div>
              <div class="form-control">
                <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Website")}</span>
                <input type="url" name="location[website]" value={Ecto.Changeset.get_field(@changeset, :website) || ""} class="input input-bordered w-full transition-colors focus:input-primary" placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "https://...")} />
                <p :for={msg <- changeset_errors(@changeset, :website)} class="text-error text-sm mt-1">{msg}</p>
              </div>
            </div>

            <div class="divider my-0"></div>

            <%!-- Features & Amenities --%>
            <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z" />
              </svg>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Features & Amenities")}
            </h2>

            <div class="grid grid-cols-2 md:grid-cols-3 gap-3">
              <label
                :for={{key, label} <- @feature_keys}
                class="flex items-center gap-2 cursor-pointer select-none"
                phx-click="toggle_feature"
                phx-value-key={key}
              >
                <input type="checkbox" class="checkbox checkbox-sm checkbox-primary" checked={Map.get(@features, key, false)} tabindex="-1" />
                <span class="label-text text-sm">{Gettext.gettext(PhoenixKitWeb.Gettext, label)}</span>
              </label>
            </div>
          </div>
        </div>

        <%!-- ═══════════════════════════════════════════════════════ --%>
        <%!-- INTERNAL                                               --%>
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <div class="card bg-base-100 shadow-lg mt-6">
          <div class="card-body flex flex-col gap-5">
            <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
              <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 15v2m-6 4h12a2 2 0 002-2v-6a2 2 0 00-2-2H6a2 2 0 00-2 2v6a2 2 0 002 2zm10-10V7a4 4 0 00-8 0v4h8z" />
              </svg>
              {Gettext.gettext(PhoenixKitWeb.Gettext, "Internal")}
            </h2>
            <p class="text-sm text-base-content/50 -mt-3">
              {Gettext.gettext(PhoenixKitWeb.Gettext, "This information is only visible to administrators.")}
            </p>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Internal Notes")}</span>
              <textarea
                name="location[notes]"
                class="textarea textarea-bordered w-full min-h-[5rem] transition-colors focus:textarea-primary"
                rows="3"
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Notes only visible to admins...")}
              >{Ecto.Changeset.get_field(@changeset, :notes) || ""}</textarea>
            </div>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</span>
              <label class="select w-full transition-colors focus-within:select-primary">
                <select name="location[status]">
                  <option value="active" selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}>{Gettext.gettext(PhoenixKitWeb.Gettext, "Active")}</option>
                  <option value="inactive" selected={Ecto.Changeset.get_field(@changeset, :status) == "inactive"}>{Gettext.gettext(PhoenixKitWeb.Gettext, "Inactive")}</option>
                </select>
              </label>
            </div>

            <%!-- Location types --%>
            <div :if={@all_types != []} class="flex flex-col gap-4">
              <div class="divider my-0"></div>

              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M7 7h.01M7 3h5c.512 0 1.024.195 1.414.586l7 7a2 2 0 010 2.828l-7 7a2 2 0 01-2.828 0l-7-7A1.994 1.994 0 013 12V7a4 4 0 014-4z" />
                </svg>
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Location Types")}
              </h2>
              <p class="text-sm text-base-content/50 -mt-2">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Click to toggle. A location can have multiple types.")}
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
                  <svg
                    :if={MapSet.member?(@linked_type_uuids, t.uuid)}
                    xmlns="http://www.w3.org/2000/svg"
                    class="h-3.5 w-3.5"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 13l4 4L19 7" />
                  </svg>
                  {t.name}
                </label>
              </div>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.link navigate={Paths.index()} class="btn btn-ghost">{Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}</.link>
              <button type="submit" class="btn btn-primary phx-submit-loading:opacity-75">
                {if @action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Create Location"), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Save Changes")}
              </button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp changeset_errors(%Ecto.Changeset{action: action, errors: errors}, field)
       when not is_nil(action) do
    errors
    |> Keyword.get_values(field)
    |> Enum.map(&translate_error/1)
  end

  defp changeset_errors(_changeset, _field), do: []

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
