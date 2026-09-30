defmodule PhoenixKitLocations.Web.LocationTypeFormLive do
  @moduledoc "Create/edit form for location types with multilang support."

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitLocations.Gettext

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.FormActions, only: [form_actions: 1]
  import PhoenixKitWeb.Components.Core.Select

  alias PhoenixKitLocations.Errors
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Policy
  alias PhoenixKitLocations.Schemas.LocationType
  alias PhoenixKitWeb.Actor

  @translatable_fields ["name", "description"]
  @preserve_fields %{"status" => :status}

  # Location types are site-wide configuration: `locations.manage_all` only.
  # The tab keeps the base permission (core maps one key per LiveView), so the
  # page refuses everyone else itself.
  @impl true
  def mount(params, _session, socket) do
    if Policy.manage_all?(socket.assigns[:phoenix_kit_current_scope]) do
      mount_type(params, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, Errors.message(:not_allowed))
       |> push_navigate(to: Paths.index())}
    end
  end

  defp mount_type(params, socket) do
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
           page_title: page_title(action),
           page_section: gettext("Locations"),
           page_section_path: Paths.index(),
           page_crumbs: page_crumbs(action, location_type),
           action: action,
           location_type: location_type
         )
         |> assign_form(changeset)
         |> mount_multilang(open_on: if(action == :edit, do: :viewing_language, else: :primary))}
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

  # Rendered by the PhoenixKit admin header as "Locations / Types / New type"
  # or "Locations / Types / <name> / Edit"; the page body has no header of its
  # own. The type crumb is text: the Types list is the record's only page.
  defp page_title(:new), do: gettext("New type")
  defp page_title(:edit), do: gettext("Edit")

  defp page_crumbs(action, location_type) do
    types = %{
      label: gettext("Types"),
      path: Paths.types()
    }

    case action do
      :new -> [types]
      :edit -> [types, %{label: location_type.name}]
    end
  end

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
    case Locations.create_location_type(params, Actor.opts(socket)) do
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
    case Locations.update_location_type(socket.assigns.location_type, params, Actor.opts(socket)) do
      {:ok, _location_type} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Location type updated."))
         |> push_navigate(to: Paths.types())}

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
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
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <div class="max-w-3xl mx-auto w-full">
      <.form for={@form} id="location-type-form" action="#" phx-change="validate" phx-submit="save">
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
            skeleton_class="card-body pt-0"
          >
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
            <div class="fieldset">
              <.select
                field={@form[:status]}
                label={gettext("Status")}
                options={[{gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
                class="transition-colors focus-within:select-primary"
              />
              <span class="fieldset-label text-base-content/50 mt-1">
                {gettext("Inactive types won't appear in the location type selection.")}
              </span>
            </div>
          </div>
        </div>

        <.form_actions
          class="mt-6"
          cancel_to={Paths.types()}
          submit_label={if @action == :new, do: gettext("Create Type"), else: gettext("Save Changes")}
          submitting_label={if @action == :new, do: gettext("Creating..."), else: gettext("Saving...")}
        />
      </.form>
      </div>
    </div>
    """
  end
end
