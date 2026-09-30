defmodule PhoenixKitLocations.Web.LocationFormLive do
  @moduledoc """
  Create/edit form for locations with multilang, type toggles, and feature
  checkboxes. What it offers depends on the scope (`PhoenixKitLocations.Policy`):

    * **`locations.manage_all`** (`@mode == :all`) — any location, the owner
      card (`OwnerComponents.owner_picker_card/1`, applied on save), the Files
      card and internal notes.
    * **base `locations` only** (`@mode == :own`) — only locations owned by the
      user or their organization: edit resolves through `Policy.get_location/2`
      at mount AND again on save, create owns the new location to the user's
      organization when they belong to one (else the user), and the
      duplicate-address warning only considers the user's own locations. No
      owner card, Files card or internal notes (the `notes` param is dropped
      server-side).

  `@mode` only drives rendering. Every write re-reads the live scope, so a
  mid-session role switch can never widen what a save does.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitLocations.Gettext

  require Logger

  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.Checkbox, only: [checkbox: 1]
  import PhoenixKitWeb.Components.Core.FormSection, only: [form_section: 1, section_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.Textarea
  import PhoenixKitLocations.Web.Components.FilesCard, only: [files_card_body: 1]
  import PhoenixKitLocations.Web.Components.LocationTabs, only: [location_tabs: 1]

  import PhoenixKitLocations.Web.Components.OwnerComponents,
    only: [owner_picker_card: 1, owner_picker_rows: 1]

  alias PhoenixKit.Users.Auth
  alias PhoenixKitLocations.Attachments
  alias PhoenixKitLocations.Errors
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Policy
  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitWeb.Actor

  @attachment_events ~w(open_featured_image_picker close_media_selector cancel_upload
                        remove_file clear_featured_image set_active_upload_scope)

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
    scope = socket.assigns[:phoenix_kit_current_scope]
    mode = if Policy.manage_all?(scope), do: :all, else: :own

    case load_location(action, params, scope, mode) do
      {:not_found, uuid} ->
        Logger.info("Location not found for edit: #{inspect(uuid)}")

        {:ok,
         socket
         |> put_flash(:error, Errors.message(:location_not_found))
         |> push_navigate(to: Paths.index())}

      {location, changeset, linked_type_uuids} ->
        all_types = safe_list_location_types()

        {:ok,
         socket
         |> assign(
           page_title: page_title(action),
           page_section: gettext("Locations"),
           page_section_path: Paths.index(),
           page_crumbs: page_crumbs(action, location),
           mode: mode,
           action: action,
           location: location,
           owner: load_owner(mode, location),
           owner_matches: [],
           all_types: all_types,
           # Types a `toggle_type` may name: the active ones offered, plus
           # whatever is already linked (an inactive type survives a save).
           allowed_type_uuids: MapSet.new(Enum.map(all_types, & &1.uuid) ++ linked_type_uuids),
           linked_type_uuids: MapSet.new(linked_type_uuids),
           features: location.features || %{},
           feature_keys: @feature_keys,
           address_warning: nil
         )
         |> assign_form(changeset)
         |> mount_multilang(open_on: if(action == :edit, do: :viewing_language, else: :primary))
         |> Attachments.init()
         |> maybe_allow_uploads(mode)
         |> Attachments.mount(scope: location_scope(), resource: location)}
    end
  end

  # The Location's scope key for the Files card. Constant — there's
  # only ever one Location per page.
  defp location_scope, do: "location"

  # A new location needs someone to own it unless the scope manages every
  # location. An edit resolves through `Policy`: a foreign, unowned or
  # malformed uuid is a not-found for anyone without `manage_all`.
  defp load_location(:new, _params, scope, mode) do
    if mode == :all or Policy.user_uuid(scope) do
      location = %Location{}
      {location, Locations.change_location(location), []}
    else
      {:not_found, nil}
    end
  end

  defp load_location(:edit, params, scope, _mode) do
    case Policy.get_location(scope, params["uuid"]) do
      nil ->
        {:not_found, params["uuid"]}

      location ->
        {location, Locations.change_location(location), safe_linked_type_uuids(location)}
    end
  end

  defp load_owner(:all, %Location{owner_uuid: owner_uuid}) when is_binary(owner_uuid) do
    case Auth.get_user(owner_uuid) do
      %{uuid: uuid, email: email} -> %{uuid: uuid, email: email}
      _ -> %{uuid: owner_uuid, email: owner_uuid}
    end
  rescue
    _ -> %{uuid: owner_uuid, email: owner_uuid}
  end

  defp load_owner(_mode, _location), do: nil

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

  # Rendered by the PhoenixKit admin header as "Locations / New location" or
  # "Locations / <name> / Edit"; the page body has no header of its own. The
  # location crumb is text: the list is the record's only page (the Structure
  # tab is a sibling of this one, not the record's page).
  defp page_title(:new), do: gettext("New location")
  defp page_title(:edit), do: gettext("Edit")

  defp page_crumbs(:new, _location), do: []
  defp page_crumbs(:edit, location), do: [%{label: location.name}]

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

    features = put_features(socket.assigns.features, params)
    params = Map.put(params, "features", features)

    changeset =
      socket.assigns.location
      |> Locations.change_location(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign_form(changeset)
     |> assign(features: features, address_warning: nil)}
  end

  def handle_event("toggle_type", %{"uuid" => uuid}, socket) do
    if MapSet.member?(socket.assigns.allowed_type_uuids, uuid) do
      linked = socket.assigns.linked_type_uuids

      linked =
        if MapSet.member?(linked, uuid),
          do: MapSet.delete(linked, uuid),
          else: MapSet.put(linked, uuid)

      {:noreply, assign(socket, :linked_type_uuids, linked)}
    else
      {:noreply, socket}
    end
  end

  # `phx-blur` payloads carry only event metadata (`%{"key" => ..., "value" => ...}`),
  # not the form's serialized params — Phoenix LV's `phx-change` is the only event
  # that serializes the form. Matching `%{"location" => params}` here crashed the LV
  # on every address-field blur with a FunctionClauseError, which auto-reconnected
  # the form and wiped every in-progress field. Read from the changeset instead,
  # which `phx-change="validate"` keeps up-to-date with each keystroke (no debounce
  # on `<.input>`).
  def handle_event("check_address", _params, socket) do
    changeset = socket.assigns.changeset

    exclude_uuid =
      if socket.assigns.action == :edit, do: socket.assigns.location.uuid, else: nil

    similar =
      Locations.find_similar_addresses(
        Ecto.Changeset.get_field(changeset, :address_line_1),
        Ecto.Changeset.get_field(changeset, :city),
        Ecto.Changeset.get_field(changeset, :postal_code),
        exclude_uuid,
        Policy.similar_address_opts(socket.assigns[:phoenix_kit_current_scope])
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

    params =
      params
      |> Map.put("features", put_features(socket.assigns.features, params))
      |> Attachments.inject_attachment_data(socket, location_scope())
      |> drop_admin_only_params(socket)

    save_location(socket, socket.assigns.action, params)
  end

  # ── Owner picker (`locations.manage_all` only) ──
  # The chosen owner is pending until save. `pick_owner` only accepts a uuid
  # from the current search results, so a forged payload can't pick an
  # arbitrary uuid; without `manage_all` every owner event is ignored.

  def handle_event(event, params, socket)
      when event in ["search_owner", "pick_owner", "clear_owner"] do
    if manage_all?(socket), do: owner_event(event, params, socket), else: {:noreply, socket}
  end

  # ── Attachments (featured image modal + inline files dropzone) ──
  # `locations.manage_all` only, checked against the live scope: hiding the
  # Files card is not the gate. Without it every file event is ignored and
  # the upload was never allowed (`maybe_allow_uploads/2`).

  def handle_event(event, params, socket) when event in @attachment_events do
    if manage_all?(socket), do: attachment_event(event, params, socket), else: {:noreply, socket}
  end

  # `pick_owner` only accepts a uuid from the rows this socket last sent, so a
  # forged payload can't pick an arbitrary user. `owner_staged` tells the
  # picker the pick landed (it clears its input).
  defp owner_event("search_owner", %{"q" => query}, socket) when is_binary(query) do
    users = safe_search_users(query)

    {:noreply,
     socket
     |> assign(owner_matches: users)
     |> push_event("owner_results", %{
       q: query,
       results: owner_picker_rows(users),
       has_more: false
     })}
  end

  defp owner_event("pick_owner", %{"uuid" => uuid}, socket) do
    case Enum.find(socket.assigns.owner_matches, &(to_string(&1.uuid) == uuid)) do
      nil ->
        {:noreply, socket}

      user ->
        {:noreply,
         socket
         |> assign(owner: %{uuid: to_string(user.uuid), email: user.email}, owner_matches: [])
         |> push_event("owner_staged", %{})}
    end
  end

  defp owner_event("clear_owner", _params, socket) do
    {:noreply, assign(socket, :owner, nil)}
  end

  defp owner_event(_event, _params, socket), do: {:noreply, socket}

  # All take a `scope` via phx-value-scope so multiple Files cards on the
  # same page route to their own state.
  defp attachment_event("open_featured_image_picker", %{"scope" => scope}, socket),
    do: Attachments.open_featured_image_picker(socket, scope)

  defp attachment_event("close_media_selector", _params, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  defp attachment_event("cancel_upload", %{"ref" => ref}, socket),
    do: Attachments.cancel_attachment_upload(socket, ref)

  defp attachment_event("remove_file", %{"scope" => scope, "uuid" => uuid}, socket),
    do: Attachments.trash_file(socket, scope, uuid)

  defp attachment_event("clear_featured_image", %{"scope" => scope}, socket),
    do: Attachments.clear_featured_image(socket, scope)

  # Marks which Files card the next upload is for. Wired to phx-click on each
  # dropzone label.
  defp attachment_event("set_active_upload_scope", %{"scope" => scope}, socket),
    do: {:noreply, Attachments.set_active_upload_scope(socket, scope)}

  defp attachment_event(_event, _params, socket), do: {:noreply, socket}

  # Uploads exist only for a site-wide manager: a scope without
  # `manage_all` never gets the upload config, so a forged upload has no
  # channel to arrive on.
  defp maybe_allow_uploads(socket, :all), do: Attachments.allow_attachment_upload(socket)
  defp maybe_allow_uploads(socket, _mode), do: socket

  # `@uploads` has no `:attachment_files` entry when uploads were never allowed.
  defp uploads_in_flight?(assigns),
    do: match?(%{attachment_files: %{entries: [_ | _]}}, assigns[:uploads])

  # Without `manage_all` a new location must have the signed-in user to own
  # it; with neither, nothing is created (fail closed, never a global row).
  defp save_location(socket, :new, params) do
    if manage_all?(socket) or Policy.user_uuid(socket.assigns[:phoenix_kit_current_scope]) do
      create_location(socket, params)
    else
      {:noreply,
       socket
       |> put_flash(:error, Errors.message(:not_allowed))
       |> push_navigate(to: Paths.index())}
    end
  end

  defp save_location(socket, :edit, params), do: update_location(socket, params)

  defp create_location(socket, params) do
    case Locations.create_location(params, Actor.opts(socket) ++ owner_opts(socket)) do
      {:ok, location} ->
        location_folder = Attachments.state(socket, location_scope()).folder_uuid

        _ =
          Attachments.maybe_rename_pending_folder_for(
            location_folder,
            location,
            Actor.opts(socket)[:actor_uuid]
          )

        sync_types_and_redirect(socket, location.uuid, gettext("Location created."))

      {:error, changeset} ->
        {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp update_location(socket, params) do
    case location_for_save(socket) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Errors.message(:location_not_found))
         |> push_navigate(to: Paths.index())}

      current ->
        case Locations.update_location(current, params, Actor.opts(socket)) do
          {:ok, location} ->
            socket
            |> maybe_apply_owner(location)
            |> sync_types_and_redirect(location.uuid, gettext("Location updated."))

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}

          # Deleted in the moment between the re-read above and the save.
          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(:error, Errors.message(reason))
             |> push_navigate(to: Paths.index())}
        end
    end
  end

  # Re-resolved through `Policy` against the live scope at save time: the
  # location may have been reassigned or deleted, or the role switched, since
  # this page mounted.
  defp location_for_save(socket) do
    Policy.get_location(socket.assigns[:phoenix_kit_current_scope], socket.assigns.location.uuid)
  end

  defp maybe_apply_owner(socket, location) do
    owner_uuid = socket.assigns.owner && socket.assigns.owner.uuid

    if not manage_all?(socket) or owner_uuid == location.owner_uuid do
      socket
    else
      case Locations.set_location_owner(location, owner_uuid, Actor.opts(socket)) do
        {:ok, _location} -> socket
        {:error, _changeset} -> put_flash(socket, :warning, Errors.message(:owner_update_failed))
      end
    end
  end

  @impl true
  def handle_info({:media_selected, file_uuids}, socket),
    do: Attachments.handle_media_selected(socket, file_uuids)

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  # Defensive catch-all for unmatched messages — e.g. future PubSub
  # broadcasts, multilang hook fall-throughs. Logs at :debug per the
  # workspace sync precedent at AGENTS.md:678-680.
  def handle_info(msg, socket) do
    Logger.debug("[LocationFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  defp sync_types_and_redirect(socket, location_uuid, message) do
    type_uuids = MapSet.to_list(socket.assigns.linked_type_uuids)

    case Locations.sync_location_types(location_uuid, type_uuids, Actor.opts(socket)) do
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
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <%!-- Folder-scoped media selector (featured-image picker). The
           dropzone in each Files card uses the LV upload channel
           directly — modal is featured-image-only. `scope_folder_id`
           pulls the folder of whichever scope opened the modal (set
           on click in `open_featured_image_picker/2`). --%>
      <.live_component
        :if={@mode == :all}
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="location-form-media-selector"
        show={@show_media_selector}
        mode={@media_selection_mode}
        file_type_filter={@media_filter}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={Attachments.state(%{assigns: assigns}, @media_selector_scope).folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <%!-- Form content capped at 5xl (matches AI module pattern). --%>
      <div class="max-w-5xl mx-auto w-full">
        <%!-- Structure tab needs a persisted uuid; :new has none. --%>
        <.location_tabs :if={@action == :edit} location={@location} active={:details} />
        <%!-- Outside #location-form, so owner searches never fire its phx-change. --%>
        <.owner_picker_card
          :if={@mode == :all}
          owner={@owner}
        />
        <.form
          for={@form}
          id="location-form"
          action="#"
          phx-change="validate"
          phx-submit="save"
        >
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <%!-- PUBLIC INFORMATION                                     --%>
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <.form_section title={gettext("Public information")} icon="hero-globe-alt" body_class="gap-5">
          <%!-- Translatable fields (name, description, public notes) --%>
          <.multilang_tabs
            multilang_enabled={@multilang_enabled}
            language_tabs={@language_tabs}
            current_lang={@current_lang}
            class=""
          />

          <.multilang_fields_wrapper
            multilang_enabled={@multilang_enabled}
            current_lang={@current_lang}
            skeleton_class="flex flex-col gap-5"
            fields_class="flex flex-col gap-5"
          >
            <:skeleton>
              <div class="fieldset">
                <div class="label"><div class="bg-base-content/15 rounded h-4 w-14 animate-pulse"></div></div>
                <div class="bg-base-content/15 rounded-lg h-12 w-full animate-pulse"></div>
              </div>
              <div class="fieldset">
                <div class="label"><div class="bg-base-content/15 rounded h-4 w-24 animate-pulse"></div></div>
                <div class="bg-base-content/15 rounded-lg h-20 w-full animate-pulse"></div>
              </div>
              <div class="fieldset">
                <div class="label"><div class="bg-base-content/15 rounded h-4 w-20 animate-pulse"></div></div>
                <div class="bg-base-content/15 rounded-lg h-20 w-full animate-pulse"></div>
              </div>
            </:skeleton>
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
          </.multilang_fields_wrapper>

            <.section_header icon="hero-map-pin" title={gettext("Address")} />

            <div :if={@address_warning} class="alert alert-warning text-sm py-2">
              <.icon name="hero-exclamation-triangle" class="h-4 w-4 shrink-0" />
              <span>{@address_warning}</span>
            </div>

            <.input
              field={@form[:address_line_1]}
              type="text"
              label={gettext("Address Line 1")}
              placeholder={gettext("Street address, P.O. box")}
            />

            <.input
              field={@form[:address_line_2]}
              type="text"
              label={gettext("Address Line 2")}
              placeholder={gettext("Apartment, suite, unit, building, floor")}
            />

            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input field={@form[:city]} type="text" label={gettext("City")} />
              <.input field={@form[:state]} type="text" label={gettext("State / Region")} />
            </div>

            <%!-- `check_address` reads all 3 address fields off the
                 changeset; one blur on postal_code (the natural
                 "I'm done with the address" point) does the same job
                 as binding to all three. --%>
            <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
              <.input
                field={@form[:postal_code]}
                type="text"
                label={gettext("Postal Code")}
                phx-blur="check_address"
              />
              <.input field={@form[:country]} type="text" label={gettext("Country")} />
            </div>

            <.section_header icon="hero-envelope" title={gettext("Contact")} />

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

            <.section_header icon="hero-check-circle" title={gettext("Features & Amenities")} />

            <%!-- Real form fields: `validate` / `save` read them from the
                 params (`put_features/2`), so they are keyboard-reachable
                 and submit like any other input. --%>
            <div class="grid grid-cols-2 md:grid-cols-3 gap-3">
              <.checkbox
                :for={key <- @feature_keys}
                id={"location-feature-#{key}"}
                name={"location[features][#{key}]"}
                checked={feature_on?(Map.get(@features, key))}
                label={feature_label(key)}
                class="checkbox-sm"
                wrapper_class="gap-2"
              />
            </div>
        </.form_section>

        <%!-- ═══════════════════════════════════════════════════════ --%>
        <%!-- FILES & FEATURED IMAGE — Location scope                --%>
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <div :if={@mode == :all} class="card bg-base-100 shadow-lg mt-6">
          <div class="card-body flex flex-col gap-4">
            <.files_card_body
              scope={location_scope()}
              state={Attachments.state(%{assigns: assigns}, location_scope())}
              uploads={@uploads}
              featured_subtitle={gettext("Shown alongside this location in listings.")}
              files_subtitle={gettext("Floor plans, brochures, certificates. Any file type is accepted.")}
              remove_file_confirm={gettext("Remove this file from the location? If it's not attached to any other resource, it will be moved to trash (admins can restore).")}
            />
          </div>
        </div>

        <%!-- ═══════════════════════════════════════════════════════ --%>
        <%!-- INTERNAL                                               --%>
        <%!-- ═══════════════════════════════════════════════════════ --%>
        <.form_section
          title={if @mode == :all, do: gettext("Internal"), else: gettext("Status")}
          icon={if @mode == :all, do: "hero-lock-closed", else: "hero-adjustments-horizontal"}
          class="mt-6"
          body_class="gap-5"
        >
          <:subtitle :if={@mode == :all}>
            {gettext("This information is only visible to administrators.")}
          </:subtitle>

            <.textarea
              :if={@mode == :all}
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
              <.section_header icon="hero-tag" title={gettext("Location Types")} />
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

        </.form_section>

        <%!-- Actions. Hand-rolled rather than core's `form_actions`:
             Save is disabled while uploads are in flight, and
             `form_actions` has no way to disable its submit button. --%>
        <div class="flex justify-end gap-3 mt-6">
          <.link navigate={Paths.index()} class="btn btn-ghost">{gettext("Cancel")}</.link>
          <button
            type="submit"
            class="btn btn-primary phx-submit-loading:opacity-75"
            disabled={uploads_in_flight?(assigns)}
            phx-disable-with={if @action == :new, do: gettext("Creating..."), else: gettext("Saving...")}
          >
            {cond do
              uploads_in_flight?(assigns) -> gettext("Waiting for uploads...")
              @action == :new -> gettext("Create Location")
              true -> gettext("Save Changes")
            end}
          </button>
        </div>
      </.form>
      </div>
    </div>
    """
  end

  # The feature checkboxes submit `"true"` / `"false"` (core's checkbox adds a
  # hidden `"false"`). Only known keys are read from the params, and keys the
  # form doesn't offer keep their stored value.
  defp put_features(features, %{"features" => submitted}) when is_map(submitted) do
    Enum.reduce(@feature_keys, features, fn key, acc ->
      case Map.fetch(submitted, key) do
        {:ok, value} -> Map.put(acc, key, value == "true")
        :error -> acc
      end
    end)
  end

  defp put_features(features, _params), do: features

  # A features map can hold `"true"` strings (an import, an older client),
  # not only booleans; both count as on.
  defp feature_on?(value), do: value in [true, "true"]

  # Every security decision reads the LIVE scope, never the mount-time `@mode`.
  defp manage_all?(socket), do: Policy.manage_all?(socket.assigns[:phoenix_kit_current_scope])

  # A new location's owner: the picked owner (or nil = global) for a
  # site-wide manager, otherwise the user's organization when they belong to
  # one (so teammates share it), else the user (`Policy.new_owner_uuid/1`).
  defp owner_opts(socket) do
    if manage_all?(socket) do
      [owner_uuid: socket.assigns.owner && socket.assigns.owner.uuid]
    else
      [owner_uuid: Policy.new_owner_uuid(socket.assigns[:phoenix_kit_current_scope])]
    end
  end

  # Internal notes need `locations.manage_all`; anyone else's submit must not
  # write them.
  defp drop_admin_only_params(params, socket) do
    if manage_all?(socket), do: params, else: Map.delete(params, "notes")
  end

  defp safe_search_users(query) do
    Auth.search_users(query)
  rescue
    error ->
      Logger.error("Owner search failed: #{inspect(error)}")
      []
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
