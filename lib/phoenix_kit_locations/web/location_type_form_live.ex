defmodule PhoenixKitLocations.Web.LocationTypeFormLive do
  @moduledoc "Create/edit form for location types with multilang support."

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitWeb.Gettext

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Select

  alias PhoenixKitLocations.Errors
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Schemas.LocationType

  @translatable_fields ["name", "description"]
  @preserve_fields %{"status" => :status}

  @impl true
  def mount(params, _session, socket) do
    action = socket.assigns.live_action

    case load_type(action, params) do
      {:not_found, uuid} ->
        Logger.info("Location type not found for edit: #{uuid}")

        {:ok,
         socket
         |> put_flash(:error, Errors.message(:location_type_not_found))
         |> push_navigate(to: Paths.types())}

      {location_type, changeset} ->
        {:ok,
         socket
         |> assign(
           page_title: page_title(action, location_type),
           action: action,
           location_type: location_type
         )
         |> assign_form(changeset)
         |> mount_multilang()}
    end
  end

  defp load_type(:new, _params) do
    t = %LocationType{}
    {t, Locations.change_location_type(t)}
  end

  defp load_type(:edit, params) do
    case Locations.get_location_type(params["uuid"]) do
      nil -> {:not_found, params["uuid"]}
      t -> {t, Locations.change_location_type(t)}
    end
  end

  defp page_title(:new, _location_type), do: gettext("New Location Type")
  defp page_title(:edit, location_type), do: gettext("Edit %{name}", name: location_type.name)

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, changeset: changeset, form: to_form(changeset, as: :location_type))
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
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"location_type" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset,
        preserve_fields: @preserve_fields
      )

    save_location_type(socket, socket.assigns.action, params)
  end

  # Defensive catch-all for unmatched messages — e.g. future PubSub
  # broadcasts, multilang hook fall-throughs. Logs at :debug per the
  # workspace sync precedent at AGENTS.md:678-680.
  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[LocationTypeFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp save_location_type(socket, :new, params) do
    case Locations.create_location_type(params, actor_opts(socket)) do
      {:ok, _location_type} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Location type created."))
         |> push_navigate(to: Paths.types())}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save_location_type(socket, :edit, params) do
    case Locations.update_location_type(socket.assigns.location_type, params, actor_opts(socket)) do
      {:ok, _location_type} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Location type updated."))
         |> push_navigate(to: Paths.types())}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
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
        subtitle={if @action == :new, do: gettext("Create a new location type for categorizing locations."), else: gettext("Update location type details.")}
      />

      <.form for={@form} action="#" phx-change="validate" phx-submit="save">
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
                label={gettext("Name")}
                placeholder={gettext("e.g., Showroom, Storage, Office")}
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
                label={gettext("Description")}
                type="textarea"
                placeholder={gettext("Brief description of this location type...")}
                class="w-full"
              />
            </div>
          </.multilang_fields_wrapper>

          <div class="card-body flex flex-col gap-5 pt-0">
            <div class="divider my-0"></div>

            <div class="form-control">
              <.select
                field={@form[:status]}
                label={gettext("Status")}
                options={[{gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
                class="transition-colors focus-within:select-primary"
              />
              <span class="label-text-alt text-base-content/50 mt-1">
                {gettext("Inactive types won't appear in the location type selection.")}
              </span>
            </div>

            <%!-- Actions --%>
            <div class="divider my-0"></div>

            <div class="flex justify-end gap-3">
              <.link navigate={Paths.types()} class="btn btn-ghost">{gettext("Cancel")}</.link>
              <button
                type="submit"
                class="btn btn-primary phx-submit-loading:opacity-75"
                phx-disable-with={if @action == :new, do: gettext("Creating..."), else: gettext("Saving...")}
              >
                {if @action == :new, do: gettext("Create Type"), else: gettext("Save Changes")}
              </button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end
end
