defmodule PhoenixKitLocations.Attachments do
  @moduledoc """
  Folder-scoped file attachments + featured image for Locations
  resources (Location, Space). Designed for **multi-resource** LVs:
  many Files cards can live on the same page, each keyed by an
  opaque string "scope" — typically the resource's id or a draft id.

  A single-resource LiveView keeps its attachment state in top-level socket
  assigns, which forces one resource per LV. Here, all that state lives in
  a per-scope map:

      socket.assigns.attachments_by_scope = %{
        "location" => %{folder_uuid: …, featured_image_uuid: …, files: […], …},
        "floor-uuid-1" => %{…},
        "new-uuid-XYZ" => %{…}
      }

  Modal state (`:show_media_selector` and friends) stays shared at
  the socket level — only one modal opens at a time — but tracks
  `:media_selector_scope` so the picker's result applies to the
  right resource.

  Uploads use a single shared config (`@upload_name`). The dropzone
  in each Files card calls `set_active_upload_scope/2` on click so
  `handle_progress/3` knows which scope's folder the file belongs to.
  Edge case: clicking dropzone A then dropzone B before either file
  picker resolves will route the next-picked file to B — accepted
  trade for keeping one upload config instead of N atom-named refs.

  ## Usage

      # Mount
      socket
      |> Attachments.mount(scope: "location", resource: location)
      |> Attachments.mount(scope: "floor-1", resource: floor)
      |> Attachments.allow_attachment_upload()

      # Render — pass scope to each Files card render
      <FilesCard scope="location" state={Attachments.state(@socket, "location")} … />
      <FilesCard scope="floor-1"  state={Attachments.state(@socket, "floor-1")}  … />

      # Events take scope via phx-value
      def handle_event("open_featured_image_picker", %{"scope" => scope}, s),
        do: Attachments.open_featured_image_picker(s, scope)

      def handle_event("set_active_upload_scope", %{"scope" => scope}, s),
        do: {:noreply, Attachments.set_active_upload_scope(s, scope)}

      # Save-time — inject for each scope
      params = Attachments.inject_attachment_data(params, socket, "location")

      # After a `:new` resource is persisted, rename its pending folder
      :ok = Attachments.maybe_rename_pending_folder_for(folder_uuid, saved_resource, actor_uuid)

  ## Resource shape

  Each scope's resource carries a `data` JSONB with
  `files_folder_uuid` and `featured_image_uuid` keys. Add a clause
  to `folder_name_for/1` to support additional resource structs.

  ## Parent folder

  By default resource folders are created at the storage root. A host can
  group them under per-type containers:

      config :phoenix_kit_locations, :attachments_parent_folder, {MyApp.Media, :for_location}

  Called as `for_location(:location | :space, actor_uuid, resource)`
  (3-arity, receiving the resource struct itself) when exported, else as
  `for_location(kind, actor_uuid)` (2-arity, the original contract). Either
  arity returns `{:ok, parent_folder_uuid}` or `nil` (root).

  ## Host-named folders

  A host that wants people-facing folder names (following the resource's
  own name, not `location-<uuid>` / `location-space-<uuid>`) configures:

      config :phoenix_kit_locations, :attachments_folder_name, {MyApp.Media, :name_for}

  called as `name_for(resource, actor_uuid) :: {:ok, name} | nil` — `nil`
  falls back to the deterministic name. `find_resource_folder/2` looks a
  saved resource's folder up in that order: the host name under the
  resolved parent, then the deterministic name under the parent, at the
  root, then anywhere — so folders that predate either setting, or that
  were moved, are still found. Only live folders count, and a stored
  pointer to a folder trashed since is replaced on the next upload. An
  unsaved resource never adopts a folder. The convention is core's
  `PhoenixKit.Modules.Storage.ResourceFolders`.

  A host name is not unique: two locations, possibly of different owners,
  can share a name under one parent. A folder found by the host name is
  therefore adopted only when no other location or space points at it, and
  a folder whose host name is taken (or rejected) under the parent is
  created, or renamed, with the deterministic name instead.
  `maybe_rename_pending_folder_for/3` only renames; it never moves the
  folder out of the parent it was created under. A hook that raises is
  logged and treated as `nil`.
  """

  use Gettext, backend: PhoenixKitLocations.Gettext

  require Logger

  import Phoenix.Component, only: [assign: 2, assign: 3]

  import Phoenix.LiveView,
    only: [
      cancel_upload: 3,
      consume_uploaded_entry: 3,
      put_flash: 3
    ]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKit.Utils.Format
  alias PhoenixKitLocations.Schemas.{Location, Space}
  alias PhoenixKitWeb.Actor
  alias PhoenixKitWeb.Attachments, as: CoreAttachments

  @upload_name :attachment_files
  @files_grid_limit 200
  @pending_prefix "location-attachment-pending-"

  @doc "Returns the upload ref name used by every Files card on the page."
  def upload_name, do: @upload_name

  @doc """
  Default empty per-scope state. Returned by `state/2` when the scope
  hasn't been mounted yet — keeps render-time templates safe to call
  before mount runs.
  """
  def empty_scope_state do
    %{
      resource: nil,
      folder_uuid: nil,
      featured_image_uuid: nil,
      featured_image_file: nil,
      files: []
    }
  end

  # ═══════════════════════════════════════════════════════════════════
  # Mount / lifecycle
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Initializes the per-scope map and shared modal assigns. Idempotent —
  safe to call multiple times; existing scope state is preserved.
  """
  def init(socket) do
    socket
    |> Phoenix.Component.assign_new(:attachments_by_scope, fn -> %{} end)
    |> Phoenix.Component.assign_new(:active_upload_scope, fn -> nil end)
    |> Phoenix.Component.assign_new(:media_selector_scope, fn -> nil end)
    |> Phoenix.Component.assign_new(:show_media_selector, fn -> false end)
    |> Phoenix.Component.assign_new(:media_selector_target, fn -> nil end)
    |> Phoenix.Component.assign_new(:media_selection_mode, fn -> :single end)
    |> Phoenix.Component.assign_new(:media_filter, fn -> :image end)
    |> Phoenix.Component.assign_new(:media_selected_uuids, fn -> [] end)
  end

  @doc """
  Registers the shared file input with a 20-file, 100MB ceiling and
  auto-upload. Progress routes to `handle_progress/3` which reads the
  active upload scope to figure out the target folder.
  """
  @spec allow_attachment_upload(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def allow_attachment_upload(socket),
    do: CoreAttachments.allow(socket, @upload_name, &handle_progress/3)

  @doc """
  Populates a single scope's state from `resource.data`. Pulls the
  folder uuid (if any) + featured image (if any) + the folder's file
  list. Existing other-scope entries are left untouched.

  ## Options

    * `:files_grid` (default `true`) — set to `false` to skip the
      per-mount DB query that enumerates the folder's files. Useful
      when the card only renders the featured-image control and
      doesn't need the grid.
  """
  def mount(socket, opts) when is_list(opts) do
    scope = Keyword.fetch!(opts, :scope)
    resource = Keyword.fetch!(opts, :resource)
    files_grid? = Keyword.get(opts, :files_grid, true)

    socket = init(socket)
    data = resource_data(resource)
    folder_uuid = read_string(data, "files_folder_uuid")
    featured_uuid = read_string(data, "featured_image_uuid")
    featured_file = if featured_uuid, do: safe_get_file(featured_uuid), else: nil

    state = %{
      resource: resource,
      folder_uuid: folder_uuid,
      featured_image_uuid: if(featured_file, do: featured_uuid, else: nil),
      featured_image_file: featured_file,
      files: if(files_grid?, do: compute_files_list(folder_uuid, featured_file), else: [])
    }

    put_scope(socket, scope, state)
  end

  @doc """
  Replaces the resource a mounted scope holds — after a save that keeps the
  form open. The host's folder hooks read the resource when the first
  upload resolves a folder, so a rename saved here must reach them; the
  files and pointers are live state already and stay as they are.
  """
  @spec put_resource(Phoenix.LiveView.Socket.t(), term(), struct()) ::
          Phoenix.LiveView.Socket.t()
  def put_resource(socket, scope, resource) do
    update_scope(socket, scope, fn st -> %{st | resource: resource} end)
  end

  @doc """
  Drops a scope's state (and clears the active-upload / modal scope
  pointers if they were pointing at this scope). Call when a draft
  is discarded so the per-scope map doesn't grow unbounded.
  """
  def forget_scope(socket, scope) do
    new_map = Map.delete(socket.assigns[:attachments_by_scope] || %{}, scope)

    socket
    |> assign(:attachments_by_scope, new_map)
    |> maybe_clear_active(:active_upload_scope, scope)
    |> maybe_clear_active(:media_selector_scope, scope)
  end

  defp maybe_clear_active(socket, key, scope) do
    if socket.assigns[key] == scope, do: assign(socket, key, nil), else: socket
  end

  # ═══════════════════════════════════════════════════════════════════
  # Render-time accessors
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Returns the per-scope state map (or the empty-state default if the
  scope hasn't been mounted). Always safe to call from a template.
  """
  def state(socket, scope) do
    Map.get(socket.assigns[:attachments_by_scope] || %{}, scope, empty_scope_state())
  end

  # ═══════════════════════════════════════════════════════════════════
  # Event handlers (all take scope where it matters)
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Marks which scope is about to receive the next upload. Wire this
  to `phx-click` on each Files card's dropzone so concurrent dropzones
  route to the right folder.
  """
  def set_active_upload_scope(socket, scope) when is_binary(scope) do
    assign(socket, :active_upload_scope, scope)
  end

  @doc """
  Opens the featured-image picker scoped to this resource's folder.
  Stores `scope` in `:media_selector_scope` so the picker's reply
  knows which scope's `:featured_image_uuid` to update.
  """
  def open_featured_image_picker(socket, scope) do
    case ensure_folder(socket, scope) do
      {:ok, _folder_uuid, socket} ->
        st = state(socket, scope)
        preselected = List.wrap(st.featured_image_uuid)

        {:noreply,
         socket
         |> assign(:media_selector_scope, scope)
         |> assign(:media_selector_target, :featured_image)
         |> assign(:media_selection_mode, :single)
         |> assign(:media_filter, :image)
         |> assign(:media_selected_uuids, preselected)
         |> assign(:show_media_selector, true)}

      {:error, reason} ->
        Logger.warning(
          "Failed to ensure attachments folder for #{scope}: " <>
            ResourceFolders.describe_failure(reason)
        )

        {:noreply, put_flash(socket, :error, CoreAttachments.folder_error_message())}
    end
  end

  @doc "Clears modal-state assigns; returns the plain socket."
  def close_media_selector(socket) do
    assign(socket,
      show_media_selector: false,
      media_selector_target: nil,
      media_selector_scope: nil,
      media_selected_uuids: []
    )
  end

  @doc "Cancels an in-flight upload entry by ref."
  def cancel_attachment_upload(socket, ref) do
    {:noreply, cancel_upload(socket, @upload_name, ref)}
  end

  @doc "Nulls the featured image pointer in the given scope (save persists)."
  def clear_featured_image(socket, scope) do
    socket =
      update_scope(socket, scope, fn st ->
        %{st | featured_image_uuid: nil, featured_image_file: nil}
      end)
      |> refresh_files(scope)

    {:noreply, socket}
  end

  @doc """
  Removes the file from the scope's folder. See per-case comments in
  `do_detach/2` — soft-trash for single-owner home folders, link
  deletion when the file is multi-resource. Also clears featured if
  the removed file was featured.
  """
  def trash_file(socket, scope, uuid) do
    st = state(socket, scope)

    case do_detach(uuid, st.folder_uuid) do
      :ok ->
        new_files = Enum.reject(st.files, &(&1.uuid == uuid))

        socket =
          socket
          |> update_scope(scope, fn st ->
            %{st | files: new_files}
          end)
          |> maybe_clear_featured_if_matches(scope, uuid)

        {:noreply, socket}

      {:error, reason} ->
        Logger.warning("Failed to remove file #{uuid} for #{scope}: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not remove file.")
         )}
    end
  end

  @doc """
  Routes the `:media_selected` reply by the modal's target. Featured-
  image target promotes the first selected UUID into the scope tracked
  by `:media_selector_scope`.
  """
  def handle_media_selected(socket, file_uuids) do
    scope = socket.assigns[:media_selector_scope]

    socket =
      cond do
        is_nil(scope) ->
          socket

        socket.assigns[:media_selector_target] == :featured_image ->
          apply_featured_image_selection(socket, scope, file_uuids)

        true ->
          refresh_files(socket, scope)
      end

    {:noreply, close_media_selector(socket)}
  end

  # ─── Upload progress ──────────────────────────────────────────────

  @doc false
  def handle_progress(@upload_name, %{done?: false}, socket), do: {:noreply, socket}

  def handle_progress(@upload_name, entry, socket) do
    scope = socket.assigns[:active_upload_scope]

    case scope && ensure_folder(socket, scope) do
      {:ok, folder_uuid, socket} ->
        consume_and_store(socket, scope, entry, folder_uuid)

      # Neither branch consumes the entry, so it is cancelled: left, it would
      # sit in the list at 100% and count against the upload's limit.
      nil ->
        Logger.warning("Upload finished but no active scope set — dropping an upload")

        {:noreply,
         socket
         |> cancel_upload(@upload_name, entry.ref)
         |> put_flash(:error, gettext("Upload failed: no target file area selected."))}

      {:error, reason} ->
        {:noreply,
         socket |> cancel_upload(@upload_name, entry.ref) |> put_upload_error(entry, reason)}
    end
  end

  defp consume_and_store(socket, scope, entry, folder_uuid) do
    case consume_uploaded_entry(socket, entry, &store_upload(&1, entry, socket, folder_uuid)) do
      {:ok, _file} ->
        {:noreply, refresh_files(socket, scope)}

      # Storage de-duplicates by content: nothing new appears and the file
      # keeps the earlier upload's name, which reads as a lost file unless
      # the uploader is told.
      {:already_attached, existing} ->
        notice = CoreAttachments.duplicate_notice(entry.client_name, existing)
        {:noreply, socket |> refresh_files(scope) |> put_flash(:info, notice)}

      {:error, reason} ->
        {:noreply, put_upload_error(socket, entry, reason)}
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Save-time helpers
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Merges `files_folder_uuid` and `featured_image_uuid` for `scope`
  into `params["data"]`. Call right before passing params to your
  context's create/update.

  The server-side scope state is the only source: a pointer the client put
  in `params["data"]` is replaced, or removed when the scope has none. A
  forged folder uuid would otherwise be stored, and the next mount would aim
  every file action at another account's folder.
  """
  def inject_attachment_data(params, socket, scope) do
    st = state(socket, scope)

    params
    |> inject_files_folder(st.folder_uuid)
    |> inject_featured_image(st.featured_image_uuid)
  end

  @doc """
  Removes any client-sent attachment pointers (`files_folder_uuid`,
  `featured_image_uuid`, `additional_photo_uuids`) from `params["data"]`,
  for create paths that never go through `inject_attachment_data/3`
  (e.g. a new Space — spaces have no gallery, so all three are forged
  there).
  """
  def drop_attachment_pointers(%{"data" => %{} = data} = params) do
    Map.put(
      params,
      "data",
      Map.drop(data, ["files_folder_uuid", "featured_image_uuid", "additional_photo_uuids"])
    )
  end

  def drop_attachment_pointers(params), do: params

  @doc """
  Renames a known pending folder UUID to the persisted resource's name
  (the host's, else the deterministic one). A folder that is not pending
  is left alone. Non-fatal: rename failures log and return `:ok`.

  Only the name changes. The folder was created under the parent resolved
  with the uploading actor, and `Storage.update_folder/3` treats an explicit
  `parent_uuid` (`nil` included) as a move: re-resolving it here could move
  the folder to the storage root.
  """
  @spec maybe_rename_pending_folder_for(String.t() | nil, any(), String.t() | nil) :: :ok
  def maybe_rename_pending_folder_for(folder_uuid, resource, actor_uuid \\ nil)

  def maybe_rename_pending_folder_for(nil, _resource, _actor_uuid), do: :ok

  def maybe_rename_pending_folder_for(folder_uuid, resource, actor_uuid)
      when is_binary(folder_uuid) do
    case folder_name_for(resource) do
      {:ok, deterministic} ->
        ResourceFolders.name_pending(
          folder_uuid,
          @pending_prefix,
          folder_name(resource, actor_uuid),
          fallback_name: deterministic
        )

      :pending ->
        :ok
    end
  end

  @doc """
  Returns `{:ok, "<prefix>-<uuid>"}` for known resource structs.
  Public so multi-scope LVs can compute the target name without
  re-implementing the prefix scheme.
  """
  @spec folder_name_for(any()) :: {:ok, String.t()} | :pending
  def folder_name_for(%Location{uuid: uuid}) when is_binary(uuid),
    do: {:ok, "location-#{uuid}"}

  def folder_name_for(%Space{uuid: uuid}) when is_binary(uuid),
    do: {:ok, "location-space-#{uuid}"}

  def folder_name_for(_), do: :pending

  @doc false
  # Host-configured parent folder; `nil` = storage root (default). Contract:
  # `fun(kind, actor_uuid, subject)` (preferred) or `fun(kind, actor_uuid)`.
  # A failing hook or a non-uuid answer degrades to the root, logged
  # (`ResourceFolders.parent_uuid/4`), instead of crashing the page.
  def parent_folder_uuid(resource, actor_uuid) do
    ResourceFolders.parent_uuid(
      :phoenix_kit_locations,
      resource_kind(resource),
      actor_uuid,
      resource
    )
  end

  defp resource_kind(%Location{}), do: :location
  defp resource_kind(%Space{}), do: :space
  defp resource_kind(_), do: :unknown

  defp deterministic_name(resource) do
    case folder_name_for(resource) do
      {:ok, name} -> name
      :pending -> @pending_prefix <> Ecto.UUID.generate()
    end
  end

  @doc false
  # Folder name: the host's (`:attachments_folder_name`, `fun(resource, actor) :: {:ok, name} | nil`)
  # or the deterministic `location-<uuid> / location-space-<uuid>` name.
  def folder_name(resource, actor_uuid) do
    host_folder_name(resource, actor_uuid) || deterministic_name(resource)
  end

  defp host_folder_name(resource, actor_uuid),
    do: ResourceFolders.host_name(:phoenix_kit_locations, resource, actor_uuid)

  @doc false
  # host name under parent (unclaimed only) → deterministic name under parent →
  # at root → anywhere (the name carries the resource's uuid). Live folders
  # only. An unsaved resource has no folder to find.
  def find_resource_folder(resource, actor_uuid) do
    case folder_name_for(resource) do
      {:ok, deterministic} ->
        ResourceFolders.resolve(
          parent: parent_folder_uuid(resource, actor_uuid),
          host_name: host_folder_name(resource, actor_uuid),
          name: deterministic,
          anywhere: true,
          claimed?: &claimed_by_other?(&1, resource)
        )

      :pending ->
        nil
    end
  end

  # The host name carries no uuid, so a same-named location (possibly another
  # account's) can own the folder it matches. Adopting that folder would show
  # and store their files on this resource; the check fails closed.
  defp claimed_by_other?(%{uuid: folder_uuid}, %{uuid: own_uuid}) do
    ResourceFolders.claimed?(folder_uuid, own_uuid, [
      {Location, {:data, "files_folder_uuid"}},
      {Space, {:data, "files_folder_uuid"}}
    ])
  end

  # ═══════════════════════════════════════════════════════════════════
  # Template helpers
  # ═══════════════════════════════════════════════════════════════════

  @doc "Renders a byte count as a human string (decimal units). Nil-safe."
  @spec format_file_size(integer() | nil) :: String.t()
  def format_file_size(bytes), do: Format.bytes(bytes, base: 1000, unknown: "—")

  @doc "Heroicon name for a file's Storage type / mime (`Format.file_icon/1`)."
  @spec file_icon(map()) :: String.t()
  defdelegate file_icon(file), to: Format

  @doc "Translates LiveView upload error atoms to user-facing text."
  @spec upload_error_message(term()) :: String.t()
  defdelegate upload_error_message(reason), to: CoreAttachments, as: :error_message

  # ═══════════════════════════════════════════════════════════════════
  # Internals — per-scope state updates
  # ═══════════════════════════════════════════════════════════════════

  defp put_scope(socket, scope, new_state) do
    new_map = Map.put(socket.assigns[:attachments_by_scope] || %{}, scope, new_state)
    assign(socket, :attachments_by_scope, new_map)
  end

  defp update_scope(socket, scope, fun) when is_function(fun, 1) do
    map = socket.assigns[:attachments_by_scope] || %{}
    current = Map.get(map, scope, empty_scope_state())
    put_scope(socket, scope, fun.(current))
  end

  defp refresh_files(socket, scope) do
    update_scope(socket, scope, fn st ->
      %{st | files: compute_files_list(st.folder_uuid, st.featured_image_file)}
    end)
  end

  defp maybe_clear_featured_if_matches(socket, scope, uuid) do
    st = state(socket, scope)

    if st.featured_image_uuid == uuid do
      update_scope(socket, scope, fn st ->
        %{st | featured_image_uuid: nil, featured_image_file: nil}
      end)
    else
      socket
    end
  end

  defp apply_featured_image_selection(socket, scope, []) do
    update_scope(socket, scope, fn st ->
      %{st | featured_image_uuid: nil, featured_image_file: nil}
    end)
  end

  defp apply_featured_image_selection(socket, scope, [uuid | _]) when is_binary(uuid) do
    case safe_get_file(uuid) do
      nil ->
        put_flash(
          socket,
          :error,
          gettext("Selected image could not be loaded.")
        )

      file ->
        socket
        |> update_scope(scope, fn st ->
          %{st | featured_image_uuid: uuid, featured_image_file: file}
        end)
        |> refresh_files(scope)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Internals — folder lifecycle
  # ═══════════════════════════════════════════════════════════════════

  # The scope's stored folder while it is live; a folder trashed in the media
  # browser since would take every upload out of sight, so the resource gets
  # its folder resolved (or a new one) instead.
  defp ensure_folder(socket, scope) do
    case ResourceFolders.live_folder(state(socket, scope).folder_uuid) do
      %{uuid: uuid} -> {:ok, uuid, socket}
      nil -> resolve_or_create_folder(socket, scope)
    end
  end

  # Race-safe: a create lost to a concurrent one takes the winner. A host
  # name taken under the parent by another resource's folder (or refused)
  # gets the uuid-bearing deterministic name instead, which cannot collide.
  # A saved resource's pointer is written in the same locked step
  # (`:claim`), not at the form's Save: a host name carries no uuid, so
  # until the pointer lands a same-named resource would take the folder
  # for its own.
  defp resolve_or_create_folder(socket, scope) do
    resource = state(socket, scope).resource
    actor = Actor.uuid(socket)
    parent_uuid = parent_folder_uuid(resource, actor)

    result =
      case folder_name_for(resource) do
        {:ok, deterministic} ->
          ResourceFolders.ensure(folder_name(resource, actor), parent_uuid, actor,
            lookup: fn -> find_resource_folder(resource, actor) end,
            fallback_name: deterministic,
            claim: &claim_folder(resource, &1)
          )

        :pending ->
          ResourceFolders.ensure(@pending_prefix <> Ecto.UUID.generate(), parent_uuid, actor)
      end

    case result do
      {:ok, %{uuid: uuid}} ->
        {:ok, uuid, update_scope(socket, scope, &Map.put(&1, :folder_uuid, uuid))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_folder(%schema{uuid: uuid}, folder),
    do: ResourceFolders.write_pointer(schema, uuid, {:data, "files_folder_uuid"}, folder.uuid)

  # ═══════════════════════════════════════════════════════════════════
  # Internals — file list query + storage I/O
  # ═══════════════════════════════════════════════════════════════════

  defp compute_files_list(nil, _featured_file), do: []

  defp compute_files_list(folder_uuid, featured_file) do
    folder_files = list_files_in_folder(folder_uuid)

    CoreAttachments.with_featured(folder_files, featured_file)
  end

  defp list_files_in_folder(folder_uuid) do
    ResourceFolders.list_files(folder_uuid, order: :oldest, limit: @files_grid_limit)
  rescue
    error ->
      Logger.warning("list_files_in_folder failed for #{folder_uuid}: #{inspect(error)}")
      []
  end

  defp safe_get_file(uuid) when is_binary(uuid) do
    Storage.get_file(uuid)
  rescue
    error ->
      Logger.warning("Failed to load Storage file #{uuid}: #{inspect(error)}")
      nil
  end

  defp safe_get_file(_), do: nil

  # Core's removal rule (`ResourceFolders.detach/2`): a link is dropped; a
  # file homed here moves to a live folder that also links it, or is
  # soft-trashed when nothing else holds it. A file not here is left alone.
  defp do_detach(file_uuid, folder_uuid) do
    case ResourceFolders.detach(file_uuid, folder_uuid) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_upload(%{path: path}, entry, socket, folder_uuid),
    do: {:ok, CoreAttachments.store(path, entry, Actor.uuid(socket), folder_uuid)}

  defp put_upload_error(socket, entry, reason) do
    Logger.warning(
      "Attachment upload failed for #{Path.basename(to_string(entry.client_name))}: " <>
        ResourceFolders.describe_failure(reason)
    )

    put_flash(socket, :error, CoreAttachments.failed_message(entry.client_name, reason))
  end

  defp inject_files_folder(params, nil) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.delete(data, "files_folder_uuid"))
  end

  defp inject_files_folder(params, folder_uuid) when is_binary(folder_uuid) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.put(data, "files_folder_uuid", folder_uuid))
  end

  defp inject_featured_image(params, nil) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.delete(data, "featured_image_uuid"))
  end

  defp inject_featured_image(params, uuid) when is_binary(uuid) do
    data = ensure_data_map(params)
    Map.put(params, "data", Map.put(data, "featured_image_uuid", uuid))
  end

  defp ensure_data_map(params) do
    case Map.get(params, "data") do
      %{} = d -> d
      _ -> %{}
    end
  end

  defp resource_data(%{data: data}) when is_map(data), do: data
  defp resource_data(_), do: %{}

  defp read_string(data, key) when is_map(data) do
    case Map.get(data, key) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end
end
