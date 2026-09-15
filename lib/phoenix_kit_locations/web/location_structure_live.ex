defmodule PhoenixKitLocations.Web.LocationStructureLive do
  @moduledoc """
  The "Structure" tab of a Location's admin page — mounts the Location,
  loads its Space tree via `Spaces.list_tree/1`, and renders it through
  `SpaceTree.space_tree/1` next to `LocationTabs.location_tabs/1` (the
  shared tab header with `LocationFormLive`'s "Details" tab).

  Besides the mount + read-only tree render (expand/collapse via
  `toggle_space_node`, node selection via `select_space`), this module
  owns the tree's CRUD surface: creating a root or child space through
  a small inline form below the tree, inline rename, sibling reorder
  (move up/down), and hard delete. Every mutating call commits straight
  to `Spaces` — the "immediate commit" model (orchestrator decision #4
  at the top of the plan): no staged drafts, no separate save step.
  Delete is the one exception to "immediate": a hard delete CASCADEs
  to the whole subtree, so `delete_space` only opens a confirmation
  modal reporting `Spaces.count_descendants/1` — the actual
  `Spaces.delete_space/2` call happens from the modal's own Delete
  button (`confirm_delete_space`), per orchestrator decision #5.

  Selecting a node also opens a detail panel below the tree — a
  multilang (name/description), status/notes/kind edit form plus its
  own Files + Featured Image card, scoped to that Space's uuid via
  `PhoenixKitLocations.Attachments`. Unlike the old staged floor/room
  flow, the Space already exists in the DB by the time it can be
  selected, so the detail panel's Save button commits straight to
  `Spaces.update_space/3` — no draft merge step.
  """

  use Phoenix.LiveView
  use Gettext, backend: PhoenixKitLocations.Gettext

  require Logger

  import PhoenixKitWeb.Components.LanguageSwitcher, only: [language_switcher: 1]
  import PhoenixKitWeb.Components.MultilangForm
  import PhoenixKitWeb.Components.Core.AdminPageHeader, only: [admin_page_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Modal, only: [confirm_modal: 1]
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.Textarea
  import PhoenixKitLocations.Web.Components.FilesCard, only: [files_card_body: 1]
  import PhoenixKitLocations.Web.Components.LocationTabs, only: [location_tabs: 1]
  import PhoenixKitLocations.Web.Components.SpaceTree, only: [space_tree: 1]

  alias PhoenixKitLocations.Attachments
  alias PhoenixKitLocations.Errors
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Policy
  alias PhoenixKitLocations.Schemas.Space
  alias PhoenixKitLocations.Spaces

  @space_translatable_fields ~w(name description)
  @space_preserve_fields %{"status" => :status, "kind" => :kind}

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    # Through `Policy`: without `locations.manage_all`, only a location the
    # user owns opens; anything else is a not-found.
    case Policy.get_location(scope, uuid) do
      nil ->
        Logger.info("Location not found for structure: #{uuid}")

        {:ok,
         socket
         |> put_flash(:error, Errors.message(:location_not_found))
         |> push_navigate(to: Paths.index())}

      location ->
        {:ok,
         socket
         |> assign(
           location: location,
           manage_all: Policy.manage_all?(scope),
           location_rechecked: false,
           tree: Spaces.list_tree(location.uuid),
           expanded: MapSet.new(),
           selected_uuid: nil,
           selected_space: nil,
           space_changeset: nil,
           space_form: nil,
           renaming_uuid: nil,
           renaming_text: "",
           adding_parent_uuid: nil,
           new_space_form: nil,
           confirm_delete: nil,
           page_title: page_title(location)
         )
         |> mount_multilang()
         |> Attachments.init()
         |> maybe_allow_uploads(Policy.manage_all?(scope))}
    end
  end

  defp page_title(location), do: gettext("%{name} — Structure", name: location.name)

  # ── Expand / select (mount skeleton) ─────────────────────────────

  # Space writes re-resolve the location through `Policy` against the live
  # scope before they run, so a location reassigned or deleted while this page
  # is open stops accepting changes. The flag lets the re-dispatched call fall
  # through to the real clause below.
  @location_writes ~w(create_space update_space_form rename_space confirm_delete_space
                      move_space_up move_space_down)

  @attachment_events ~w(open_featured_image_picker close_media_selector cancel_upload
                        remove_file clear_featured_image set_active_upload_scope)

  @impl true
  def handle_event(event, params, %{assigns: %{location_rechecked: false}} = socket)
      when event in @location_writes do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case Policy.get_location(scope, socket.assigns.location.uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Errors.message(:location_not_found))
         |> push_navigate(to: Paths.index())}

      location ->
        {:noreply, socket} =
          handle_event(
            event,
            params,
            assign(socket, location: location, location_rechecked: true)
          )

        {:noreply, assign(socket, :location_rechecked, false)}
    end
  end

  def handle_event("toggle_space_node", %{"uuid" => uuid}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, uuid),
        do: MapSet.delete(expanded, uuid),
        else: MapSet.put(expanded, uuid)

    {:noreply, assign(socket, :expanded, expanded)}
  end

  def handle_event("select_space", %{"uuid" => uuid}, socket) do
    case find_node(socket.assigns.tree, uuid) do
      nil -> {:noreply, socket}
      space -> {:noreply, assign_selected_space(socket, space)}
    end
  end

  # ── Detail panel — multilang language switch ─────────────────────

  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  # ── Detail panel — edit form ───────────────────────────────────────

  def handle_event("validate_space_form", %{"space" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @space_translatable_fields,
        changeset: socket.assigns.space_changeset,
        preserve_fields: @space_preserve_fields
      )

    changeset =
      socket.assigns.selected_space
      |> Spaces.change_space(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_space_form(socket, changeset)}
  end

  def handle_event("update_space_form", %{"space" => params}, socket) do
    params =
      merge_translatable_params(params, socket, @space_translatable_fields,
        changeset: socket.assigns.space_changeset,
        preserve_fields: @space_preserve_fields
      )

    params = Attachments.inject_attachment_data(params, socket, socket.assigns.selected_uuid)

    case Spaces.update_space(
           socket.assigns.selected_space,
           drop_admin_only_params(params, socket),
           actor_opts(socket)
         ) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:tree, Spaces.list_tree(socket.assigns.location.uuid))
         |> assign(:selected_space, updated)
         |> assign_space_form(Spaces.change_space(updated))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_space_form(socket, changeset)}
    end
  end

  # ── Detail panel — attachments (featured image modal + files) ────
  # Mirrors LocationFormLive's attachment handlers. All events take a
  # `scope` via phx-value-scope — here that's always the selected
  # Space's uuid.

  # `locations.manage_all` only, checked against the live scope: hiding the
  # Files card is not the gate.
  def handle_event(event, params, socket) when event in @attachment_events do
    if Policy.manage_all?(socket.assigns[:phoenix_kit_current_scope]),
      do: attachment_event(event, params, socket),
      else: {:noreply, socket}
  end

  # ── Add root / child space ───────────────────────────────────────

  def handle_event("open_add_root", _params, socket) do
    {:noreply, assign(socket, adding_parent_uuid: :root, new_space_form: new_space_form())}
  end

  # Only a node of this location's tree can be a parent; a forged or
  # malformed uuid is ignored.
  def handle_event("open_add_child", %{"parent_uuid" => parent_uuid}, socket) do
    if find_node(socket.assigns.tree, parent_uuid) do
      {:noreply,
       assign(socket, adding_parent_uuid: parent_uuid, new_space_form: new_space_form())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_add_space", _params, socket) do
    {:noreply, assign(socket, adding_parent_uuid: nil, new_space_form: nil)}
  end

  def handle_event("validate_new_space", %{"space" => params}, socket) do
    changeset =
      %Space{}
      |> Spaces.change_space(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :new_space_form, to_form(changeset, as: :space))}
  end

  def handle_event("create_space", %{"space" => params}, socket) do
    location = socket.assigns.location
    parent_uuid = normalize_parent_uuid(socket.assigns.adding_parent_uuid)

    attrs =
      params
      |> drop_admin_only_params(socket)
      |> Attachments.drop_attachment_pointers()
      |> Map.merge(%{"location_uuid" => location.uuid, "parent_uuid" => parent_uuid})

    case Spaces.create_space(attrs, actor_opts(socket)) do
      {:ok, space} ->
        {:noreply,
         socket
         |> assign(:tree, Spaces.list_tree(location.uuid))
         |> assign(:expanded, expand_parent(socket.assigns.expanded, parent_uuid))
         |> assign(:adding_parent_uuid, nil)
         |> assign(:new_space_form, nil)
         |> assign_selected_space(space)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :new_space_form, to_form(changeset, as: :space))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Errors.message(reason))}
    end
  end

  # ── Inline rename ────────────────────────────────────────────────

  def handle_event("start_rename_space", %{"uuid" => uuid}, socket) do
    case space_in_location(socket, uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, Errors.message(:space_not_found))}

      space ->
        {:noreply, assign(socket, renaming_uuid: uuid, renaming_text: space.name)}
    end
  end

  def handle_event("rename_space_input", %{"name" => name}, socket) do
    {:noreply, assign(socket, :renaming_text, name)}
  end

  def handle_event("cancel_rename_space", _params, socket) do
    {:noreply, assign(socket, renaming_uuid: nil, renaming_text: "")}
  end

  def handle_event("rename_space", %{"uuid" => uuid, "name" => name}, socket) do
    case space_in_location(socket, uuid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, Errors.message(:space_not_found))
         |> assign(renaming_uuid: nil, renaming_text: "")}

      space ->
        {:noreply, submit_rename(socket, space, name)}
    end
  end

  # ── Reorder ───────────────────────────────────────────────────────

  def handle_event("move_space_up", %{"uuid" => uuid}, socket) do
    {:noreply, move_sibling(socket, uuid, -1)}
  end

  def handle_event("move_space_down", %{"uuid" => uuid}, socket) do
    {:noreply, move_sibling(socket, uuid, 1)}
  end

  # ── Delete — modal confirmation (decision #5: hard delete + CASCADE
  # always requires a confirm step showing the descendant count) ─────

  # `space_tree_node/1`'s trash button — opens the confirmation modal,
  # never deletes directly. `Spaces.count_descendants/1` runs once,
  # here, so the modal's copy and every re-render agree on the same
  # count instead of re-querying on every paint.
  def handle_event("delete_space", %{"uuid" => uuid}, socket) do
    case space_in_location(socket, uuid) do
      nil ->
        {:noreply, put_flash(socket, :error, Errors.message(:space_not_found))}

      space ->
        confirm = %{
          uuid: space.uuid,
          name: space.name,
          descendant_count: Spaces.count_descendants(space.uuid)
        }

        {:noreply, assign(socket, :confirm_delete, confirm)}
    end
  end

  def handle_event("cancel_delete_space", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  # The modal's own Delete button — the only place a Space is actually
  # removed. Re-fetches rather than trusting the uuid captured when the
  # modal opened, in case the space was deleted from elsewhere in the
  # meantime.
  def handle_event("confirm_delete_space", _params, socket) do
    case socket.assigns.confirm_delete do
      nil ->
        {:noreply, socket}

      %{uuid: uuid} ->
        socket = assign(socket, :confirm_delete, nil)

        case space_in_location(socket, uuid) do
          nil -> {:noreply, put_flash(socket, :error, Errors.message(:space_not_found))}
          space -> {:noreply, submit_delete(socket, space)}
        end
    end
  end

  # ── Attachments — reply messages from MediaSelectorModal ──────────

  @impl true
  def handle_info({:media_selected, file_uuids}, socket),
    do: Attachments.handle_media_selected(socket, file_uuids)

  def handle_info({:media_selector_closed}, socket),
    do: {:noreply, Attachments.close_media_selector(socket)}

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :space_lang_data,
        get_lang_data(assigns.space_changeset, assigns.current_lang, assigns.multilang_enabled)
      )

    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <%!-- Folder-scoped media selector (featured-image picker) for the
           selected Space's Files card. Mirrors LocationFormLive's modal
           — `scope_folder_id` pulls the folder of whichever scope
           opened it (set on click in `open_featured_image_picker/2`). --%>
      <.live_component
        :if={@manage_all}
        module={PhoenixKitWeb.Live.Components.MediaSelectorModal}
        id="location-structure-media-selector"
        show={@show_media_selector}
        mode={@media_selection_mode}
        file_type_filter={@media_filter}
        selected_uuids={@media_selected_uuids}
        scope_folder_id={Attachments.state(%{assigns: assigns}, @media_selector_scope).folder_uuid}
        phoenix_kit_current_user={assigns[:phoenix_kit_current_user]}
      />

      <.admin_page_header title={@location.name} />

      <div class="max-w-5xl mx-auto w-full flex flex-col gap-4">
        <.location_tabs location={@location} active={:structure} />

        <div class="card bg-base-100 shadow-lg">
          <div class="card-body">
            <.space_tree
              tree={@tree}
              expanded={@expanded}
              selected_uuid={@selected_uuid}
              renaming_uuid={@renaming_uuid}
              renaming_text={@renaming_text}
              myself={nil}
            />
          </div>
        </div>

        <div :if={@adding_parent_uuid} class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
              <.icon name="hero-plus" class="w-4 h-4" />
              {add_space_heading(@tree, @adding_parent_uuid)}
            </h2>

            <.form
              for={@new_space_form}
              id="new-space-form"
              action="#"
              phx-change="validate_new_space"
              phx-submit="create_space"
              class="flex flex-col gap-4"
            >
              <div class="flex flex-col sm:flex-row gap-4">
                <.select
                  field={@new_space_form[:kind]}
                  label={gettext("Kind")}
                  options={Enum.map(Space.kinds(), &{Space.kind_label(&1), &1})}
                  class="sm:w-48"
                />
                <.input
                  field={@new_space_form[:name]}
                  type="text"
                  label={gettext("Name")}
                  required
                  class="flex-1"
                />
              </div>

              <div class="flex items-center gap-2">
                <button type="submit" class="btn btn-primary btn-sm">
                  {gettext("Add")}
                </button>
                <button type="button" phx-click="cancel_add_space" class="btn btn-ghost btn-sm">
                  {gettext("Cancel")}
                </button>
              </div>
            </.form>
          </div>
        </div>

        <%!-- Detail panel — appears once a tree node is selected. Full
             multilang edit form (kind/status/name/description/notes)
             plus the selected Space's own Files + Featured Image card,
             scoped by its uuid. --%>
        <div :if={@selected_uuid} class="card bg-base-100 shadow-lg">
          <div class="card-body gap-4">
            <div class="flex flex-col gap-1">
              <p class="text-xs text-base-content/50 truncate">
                {breadcrumb(@location, @tree, @selected_uuid, @current_lang)}
              </p>
              <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
                <.icon name={Space.kind_icon(@selected_space.kind)} class="w-4 h-4" />
                {@selected_space.name}
              </h2>
            </div>

            <.language_switcher
              :if={@multilang_enabled and match?([_, _ | _], @language_tabs)}
              languages={@language_tabs}
              current_language={@current_lang}
              on_click="switch_language"
              show_flags={true}
              show_primary={true}
              primary_divider={true}
              variant={:tabs}
              size={:sm}
            />

            <.form
              for={@space_form}
              id="space-detail-form"
              action="#"
              phx-change="validate_space_form"
              phx-submit="update_space_form"
              class="flex flex-col gap-4"
            >
              <div class="flex flex-col sm:flex-row gap-4">
                <.select
                  field={@space_form[:kind]}
                  label={gettext("Kind")}
                  options={Enum.map(Space.kinds(), &{Space.kind_label(&1), &1})}
                  class="sm:w-48"
                />
                <.select
                  field={@space_form[:status]}
                  label={gettext("Status")}
                  options={[{gettext("Active"), "active"}, {gettext("Inactive"), "inactive"}]}
                  class="sm:w-48"
                />
              </div>

              <.translatable_field
                field_name="name"
                form_prefix="space"
                changeset={@space_changeset}
                schema_field={:name}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@space_lang_data}
                label={gettext("Name")}
                required
                class="w-full"
              />

              <.translatable_field
                field_name="description"
                form_prefix="space"
                changeset={@space_changeset}
                schema_field={:description}
                multilang_enabled={@multilang_enabled}
                current_lang={@current_lang}
                primary_language={@primary_language}
                lang_data={@space_lang_data}
                label={gettext("Description")}
                type="textarea"
                class="w-full"
              />

              <.textarea
                :if={@manage_all}
                field={@space_form[:notes]}
                label={gettext("Internal notes (admin-only)")}
                rows="2"
                class="min-h-[4rem]"
              />

              <%!-- Files + Featured image, scoped to this Space's uuid.
                   `PkLocationsUploadScope` (colocated with
                   `files_card_body/1`) is already compiled into the
                   shared JS manifest — nothing to wire here. --%>
              <%!-- Files need `manage_all`: the media picker only confines
                   browsing to a folder once one exists. --%>
              <div :if={@manage_all} class="border-t border-base-300 pt-4 flex flex-col gap-4">
                <.files_card_body
                  scope={@selected_uuid}
                  state={Attachments.state(%{assigns: assigns}, @selected_uuid)}
                  uploads={@uploads}
                  featured_subtitle={gettext("Shown for this space.")}
                  files_subtitle={gettext("Photos, layouts, anything specific to this space.")}
                  remove_file_confirm={gettext("Remove this file from the space?")}
                />
              </div>

              <div class="flex justify-end pt-2">
                <button
                  type="submit"
                  class="btn btn-primary btn-sm phx-submit-loading:opacity-75"
                  disabled={uploads_in_flight?(assigns)}
                  phx-disable-with={gettext("Saving...")}
                >
                  {gettext("Save")}
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>

      <%!-- Delete confirmation — decision #5: hard delete cascades to the
           whole subtree, so it's never triggered directly from the tree
           row's trash icon (see `SpaceTree`'s moduledoc). `delete_space`
           only opens this; `confirm_delete_space` (the modal's own
           button) is the sole path that actually calls `Spaces.delete_space/2`. --%>
      <.confirm_modal
        show={@confirm_delete != nil}
        on_confirm="confirm_delete_space"
        on_cancel="cancel_delete_space"
        title={gettext("Delete Space")}
        title_icon="hero-trash"
        messages={[{:warning, delete_confirm_message(@confirm_delete)}]}
        confirm_text={gettext("Delete")}
        danger={true}
      />
    </div>
    """
  end

  # ── Internals ─────────────────────────────────────────────────────

  defp actor_opts(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> [actor_uuid: uuid]
      _ -> []
    end
  end

  # Space internal notes need `locations.manage_all`, checked against the live
  # scope like every write.
  defp drop_admin_only_params(params, socket) do
    if Policy.manage_all?(socket.assigns[:phoenix_kit_current_scope]),
      do: params,
      else: Map.delete(params, "notes")
  end

  # Scope is always the selected Space's uuid here.
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

  defp attachment_event("set_active_upload_scope", %{"scope" => scope}, socket),
    do: {:noreply, Attachments.set_active_upload_scope(socket, scope)}

  defp attachment_event(_event, _params, socket), do: {:noreply, socket}

  # Uploads exist only for a site-wide manager; without `manage_all` there is
  # no upload config for a forged upload to arrive on.
  defp maybe_allow_uploads(socket, true), do: Attachments.allow_attachment_upload(socket)
  defp maybe_allow_uploads(socket, false), do: socket

  # `@uploads` has no `:attachment_files` entry when uploads were never allowed.
  defp uploads_in_flight?(assigns),
    do: match?(%{attachment_files: %{entries: [_ | _]}}, assigns[:uploads])

  defp new_space_form, do: to_form(Spaces.change_space(%Space{}), as: :space)

  # Warning copy for the delete-confirmation modal. `nil` (modal
  # closed) renders into `confirm_modal`'s `messages` assign anyway —
  # HEEx evaluates the attribute regardless of `show` — but `show`
  # being `false` keeps it off-screen, so the empty string is never
  # actually seen. `descendant_count == 0` drops the "and its N
  # descendants" clause entirely rather than reading "...and its 0
  # descendants".
  defp delete_confirm_message(nil), do: ""

  defp delete_confirm_message(%{name: name, descendant_count: 0}) do
    gettext(~s(Delete "%{name}"? This cannot be undone.), name: name)
  end

  defp delete_confirm_message(%{name: name, descendant_count: count}) do
    gettext(~s(Delete "%{name}" and its %{count} descendants? This cannot be undone.),
      name: name,
      count: count
    )
  end

  defp normalize_parent_uuid(:root), do: nil
  defp normalize_parent_uuid(uuid) when is_binary(uuid), do: uuid

  defp expand_parent(expanded, nil), do: expanded
  defp expand_parent(expanded, parent_uuid), do: MapSet.put(expanded, parent_uuid)

  defp add_space_heading(_tree, :root), do: gettext("Add root space")

  defp add_space_heading(tree, parent_uuid) do
    case find_node(tree, parent_uuid) do
      nil -> gettext("Add space")
      node -> gettext("Add space under %{name}", name: node.name)
    end
  end

  defp submit_rename(socket, space, name) do
    case Spaces.update_space(space, %{"name" => name}, actor_opts(socket)) do
      {:ok, updated} ->
        socket =
          socket
          |> assign(:tree, Spaces.list_tree(socket.assigns.location.uuid))
          |> assign(renaming_uuid: nil, renaming_text: "")

        # Keep the detail panel in sync when the renamed node is the
        # one it's currently showing — otherwise the panel's Name
        # field would keep displaying the pre-rename value until the
        # user re-selects the node.
        if socket.assigns.selected_uuid == updated.uuid,
          do: assign_selected_space(socket, updated),
          else: socket

      {:error, %Ecto.Changeset{}} ->
        put_flash(socket, :error, gettext("Failed to rename space"))

      {:error, reason} ->
        put_flash(socket, :error, Errors.message(reason))
    end
  end

  defp submit_delete(socket, space) do
    case Spaces.delete_space(space, actor_opts(socket)) do
      {:ok, _deleted} ->
        tree = Spaces.list_tree(socket.assigns.location.uuid)
        socket = assign(socket, :tree, tree)

        # A delete cascades to the whole subtree — not just the
        # deleted node itself. Clear the selection whenever it no
        # longer resolves in the refreshed tree (covers both "this
        # exact node was deleted" and "an ancestor was deleted,
        # taking the selected descendant down with it"), so the
        # detail panel below never keeps editing/showing a Space
        # that's gone from the DB.
        if socket.assigns.selected_uuid && find_node(tree, socket.assigns.selected_uuid),
          do: socket,
          else: clear_selected_space(socket)

      {:error, _changeset} ->
        put_flash(socket, :error, gettext("Failed to delete space"))
    end
  end

  defp move_sibling(socket, uuid, direction) do
    case locate(socket.assigns.tree, uuid) do
      nil ->
        put_flash(socket, :error, Errors.message(:space_not_found))

      {siblings, index} ->
        target = index + direction

        if target in 0..(length(siblings) - 1) do
          apply_reorder(socket, siblings, index, target)
        else
          socket
        end
    end
  end

  defp apply_reorder(socket, siblings, index, target) do
    location = socket.assigns.location
    parent_uuid = siblings |> hd() |> Map.get(:parent_uuid)
    reordered_uuids = siblings |> Enum.map(& &1.uuid) |> swap(index, target)

    case Spaces.reorder_siblings(location.uuid, parent_uuid, reordered_uuids, actor_opts(socket)) do
      {:ok, :reordered} -> assign(socket, :tree, Spaces.list_tree(location.uuid))
      {:error, reason} -> put_flash(socket, :error, Errors.message(reason))
    end
  end

  defp swap(list, i, j) do
    vi = Enum.at(list, i)
    vj = Enum.at(list, j)

    list
    |> List.replace_at(i, vj)
    |> List.replace_at(j, vi)
  end

  # Resolves a client-supplied space uuid only when the space belongs to the
  # location this page loaded (itself resolved through `Policy`), so a forged
  # uuid can't rename or delete a space in another location.
  defp space_in_location(socket, uuid) do
    location_uuid = socket.assigns.location.uuid

    with {:ok, _} <- Ecto.UUID.cast(uuid),
         %Space{location_uuid: ^location_uuid} = space <- Spaces.get_space(uuid) do
      space
    else
      _ -> nil
    end
  end

  defp find_node(tree, uuid) do
    case locate(tree, uuid) do
      {siblings, index} -> Enum.at(siblings, index)
      nil -> nil
    end
  end

  # Recursively finds `uuid`'s containing sibling list and its index
  # within it — shared by the reorder handlers (need the full ordered
  # sibling group to hand `Spaces.reorder_siblings/4`) and
  # `find_node/2` (needs just the node). Returns `nil` if `uuid` isn't
  # anywhere in `tree`.
  defp locate(tree, uuid) do
    case Enum.find_index(tree, &(&1.uuid == uuid)) do
      nil -> Enum.find_value(tree, &locate(&1.children, uuid))
      index -> {tree, index}
    end
  end

  # ── Detail panel — selection state ─────────────────────────────────

  # Selects `space` and loads everything the detail panel needs to
  # render it: the working changeset/form pair and its Attachments
  # scope (lazily mounted here rather than for the whole tree up
  # front — trees can run deep). Shared by `select_space`, a
  # successful `create_space` (auto-selects the new node), and a
  # successful rename of the currently-selected node.
  defp assign_selected_space(socket, %Space{} = space) do
    socket
    |> assign(:selected_uuid, space.uuid)
    |> assign(:selected_space, space)
    |> assign_space_form(Spaces.change_space(space))
    |> Attachments.mount(scope: space.uuid, resource: space)
  end

  # Clears the selection — used when the selected node (or an
  # ancestor of it) is deleted out from under the panel.
  defp clear_selected_space(socket) do
    assign(socket, selected_uuid: nil, selected_space: nil, space_changeset: nil, space_form: nil)
  end

  # Keeps `:space_changeset` (read by `<.translatable_field>`) and
  # `:space_form` (read by `<.select>` / `<.textarea>`) in sync —
  # mirrors `LocationFormLive.assign_form/2`.
  defp assign_space_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, space_changeset: changeset, space_form: to_form(changeset, as: :space))
  end

  # "Location name / Floor 1 / Zone A / Shelf 3" — the location plus
  # the selected node's ancestor chain, root-first. Uses
  # `Spaces.translated_name/2` so each segment respects the active
  # locale (same `_name`/`name` fallback chain as `Spaces.full_path/2`).
  defp breadcrumb(location, tree, uuid, locale) do
    Enum.join(
      [Spaces.translated_name(location, locale) | ancestor_chain(tree, uuid, locale)],
      " / "
    )
  end

  # Translated names of every node from the root ancestor down to (and
  # including) `uuid`, found by walking the already-loaded `:tree` —
  # no extra DB query. `[]` if `uuid` isn't in the tree.
  defp ancestor_chain(tree, uuid, locale) do
    case find_path(tree, uuid) do
      nil -> []
      path -> Enum.map(path, &Spaces.translated_name(&1, locale))
    end
  end

  defp find_path(nodes, uuid) do
    Enum.find_value(nodes, &find_path_from(&1, uuid))
  end

  defp find_path_from(%{uuid: uuid} = node, uuid), do: [node]

  defp find_path_from(node, uuid) do
    case find_path(node.children, uuid) do
      nil -> nil
      rest -> [node | rest]
    end
  end
end
