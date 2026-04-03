defmodule PhoenixKitLocations.Web.LocationTypeFormLive do
  @moduledoc "Create/edit form for location types with multilang support."

  use Phoenix.LiveView

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Schemas.LocationType

  @translatable_fields ["name", "description"]
  @preserve_fields %{"status" => :status}

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    {location_type, changeset} =
      case action do
        :new ->
          t = %LocationType{}
          {t, Locations.change_location_type(t)}

        :edit ->
          case Locations.get_location_type(params["uuid"]) do
            nil ->
              Logger.warning("Location type not found for edit: #{params["uuid"]}")
              {nil, nil}

            t ->
              {t, Locations.change_location_type(t)}
          end
      end

    if is_nil(location_type) and action == :edit do
      {:ok,
       socket
       |> put_flash(:error, Gettext.gettext(PhoenixKitWeb.Gettext, "Location type not found."))
       |> push_navigate(to: Paths.types())}
    else
      {:ok,
       socket
       |> assign(
         page_title:
           if(action == :new,
             do: Gettext.gettext(PhoenixKitWeb.Gettext, "New Location Type"),
             else:
               Gettext.gettext(PhoenixKitWeb.Gettext, "Edit %{name}", name: location_type.name)
           ),
         action: action,
         location_type: location_type,
         changeset: changeset
       )
       |> mount_multilang()}
    end
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"location_type" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    changeset =
      socket.assigns.location_type
      |> Locations.change_location_type(params)
      |> Map.put(:action, socket.assigns.changeset.action)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"location_type" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    save_location_type(socket, socket.assigns.action, params)
  end

  defp save_location_type(socket, :new, params) do
    case Locations.create_location_type(params) do
      {:ok, _location_type} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Location type created."))
         |> push_navigate(to: Paths.types())}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_location_type(socket, :edit, params) do
    case Locations.update_location_type(socket.assigns.location_type, params) do
      {:ok, _location_type} ->
        {:noreply,
         socket
         |> put_flash(:info, Gettext.gettext(PhoenixKitWeb.Gettext, "Location type updated."))
         |> push_navigate(to: Paths.types())}

      {:error, changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
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
        back={Paths.types()}
        title={@page_title}
        subtitle={if @action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Create a new location type for categorizing locations."), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Update location type details.")}
      />

      <.form for={to_form(@changeset)} action="#" phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-lg">
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
            </:skeleton>
            <div class="card-body pt-0 flex flex-col gap-5">
              <.translatable_field
                field_name="name"
                form_prefix="location_type"
                changeset={@changeset}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Name")}
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "e.g., Showroom, Storage, Office")}
                required
                class="w-full"
              />

              <.translatable_field
                field_name="description"
                form_prefix="location_type"
                changeset={@changeset}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@lang_data}
                label={Gettext.gettext(PhoenixKitWeb.Gettext, "Description")}
                type="textarea"
                placeholder={Gettext.gettext(PhoenixKitWeb.Gettext, "Brief description of this location type...")}
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <div class="divider my-0"></div>

            <div class="form-control">
              <span class="label-text font-semibold mb-2">{Gettext.gettext(PhoenixKitWeb.Gettext, "Status")}</span>
              <label class="select w-full transition-colors focus-within:select-primary">
                <select name="location_type[status]">
                  <option value="active" selected={Ecto.Changeset.get_field(@changeset, :status) == "active"}>
                    Active
                  </option>
                  <option value="inactive" selected={Ecto.Changeset.get_field(@changeset, :status) == "inactive"}>
                    Inactive
                  </option>
                </select>
              </label>
              <span class="label-text-alt text-base-content/50 mt-1">
                {Gettext.gettext(PhoenixKitWeb.Gettext, "Inactive types won't appear in the location type selection.")}
              </span>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.link navigate={Paths.types()} class="btn btn-ghost">{Gettext.gettext(PhoenixKitWeb.Gettext, "Cancel")}</.link>
              <button type="submit" class="btn btn-primary phx-submit-loading:opacity-75">
                {if @action == :new, do: Gettext.gettext(PhoenixKitWeb.Gettext, "Create Type"), else: Gettext.gettext(PhoenixKitWeb.Gettext, "Save Changes")}
              </button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
