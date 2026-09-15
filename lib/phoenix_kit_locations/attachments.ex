defmodule PhoenixKitLocations.Attachments do
  @moduledoc """
  Folder-scoped file attachments + featured image for Locations
  resources (Location, Space). Designed for **multi-resource** LVs:
  many Files cards can live on the same page, each keyed by an
  opaque string "scope" — typically the resource's id or a draft id.

  This is a re-shape of the single-resource Attachments pattern in
  `PhoenixKitCatalogue.Attachments`. Catalogue's version stores
  everything in top-level socket assigns (`:files_folder_uuid`,
  `:featured_image_uuid`, …), which forces one resource per LV.
  Here, all that state lives in a per-scope map:

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
      :ok = Attachments.maybe_rename_pending_folder_for(folder_uuid, saved_resource)

  ## Resource shape

  Each scope's resource carries a `data` JSONB with
  `files_folder_uuid` and `featured_image_uuid` keys. Add a clause
  to `folder_name_for/1` to support additional resource structs.
  """

  require Logger

  import Ecto.Query, warn: false
  import Phoenix.Component, only: [assign: 2, assign: 3]

  import Phoenix.LiveView,
    only: [
      allow_upload: 3,
      cancel_upload: 3,
      consume_uploaded_entry: 3,
      put_flash: 3
    ]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{File, FolderLink}
  alias PhoenixKit.Users.Auth, as: UsersAuth
  alias PhoenixKitLocations.Schemas.{Location, Space}

  @upload_name :attachment_files
  @files_grid_limit 200

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
  def allow_attachment_upload(socket) do
    allow_upload(socket, @upload_name,
      accept: :any,
      max_entries: 20,
      max_file_size: 100_000_000,
      auto_upload: true,
      progress: &handle_progress/3
    )
  end

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
        Logger.warning("Failed to ensure attachments folder for #{scope}: #{inspect(reason)}")

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Could not prepare the files folder.")
         )}
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
           Gettext.gettext(PhoenixKitWeb.Gettext, "Could not remove file.")
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

      nil ->
        Logger.warning("Upload finished but no active scope set — dropping #{entry.client_name}")

        {:noreply,
         put_flash(
           socket,
           :error,
           Gettext.gettext(PhoenixKitWeb.Gettext, "Upload failed: no target file area selected.")
         )}

      {:error, reason} ->
        {:noreply, put_upload_error(socket, entry, reason)}
    end
  end

  defp consume_and_store(socket, scope, entry, folder_uuid) do
    case consume_uploaded_entry(socket, entry, &store_upload(&1, entry, socket, folder_uuid)) do
      {:ok, _file} -> {:noreply, refresh_files(socket, scope)}
      {:error, reason} -> {:noreply, put_upload_error(socket, entry, reason)}
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
  Removes any client-sent `files_folder_uuid` / `featured_image_uuid` from
  `params["data"]`, for create paths that never go through
  `inject_attachment_data/3` (e.g. a new Space).
  """
  def drop_attachment_pointers(%{"data" => %{} = data} = params) do
    Map.put(params, "data", Map.drop(data, ["files_folder_uuid", "featured_image_uuid"]))
  end

  def drop_attachment_pointers(params), do: params

  @doc """
  Renames a known pending folder UUID to match the resource's
  deterministic name. Non-fatal: rename failures log and return `:ok`.
  """
  @spec maybe_rename_pending_folder_for(String.t() | nil, any()) :: :ok
  def maybe_rename_pending_folder_for(nil, _resource), do: :ok

  def maybe_rename_pending_folder_for(folder_uuid, resource) when is_binary(folder_uuid) do
    with {:ok, target_name} <- folder_name_for(resource),
         %{} = folder <- Storage.get_folder(folder_uuid),
         current_name when current_name != target_name <- folder.name do
      case Storage.update_folder(folder, %{name: target_name}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "Pending folder rename failed for #{inspect(resource.__struct__)} #{resource.uuid}: #{inspect(reason)}"
          )

          :ok
      end
    else
      _ -> :ok
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

  # ═══════════════════════════════════════════════════════════════════
  # Template helpers
  # ═══════════════════════════════════════════════════════════════════

  @doc "Renders a byte count as a human string. Nil-safe."
  def format_file_size(nil), do: "—"

  def format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      bytes >= 1_000 -> "#{Float.round(bytes / 1_000, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  def format_file_size(_), do: "—"

  @doc "Picks a heroicon name for a file based on its Storage type."
  def file_icon(%{file_type: "image"}), do: "hero-photo"
  def file_icon(%{file_type: "video"}), do: "hero-film"
  def file_icon(%{file_type: "audio"}), do: "hero-musical-note"
  def file_icon(%{file_type: "archive"}), do: "hero-archive-box"
  def file_icon(%{mime_type: "application/pdf"}), do: "hero-document-text"
  def file_icon(_), do: "hero-document"

  @doc "Translates LiveView upload error atoms to user-facing text."
  def upload_error_message(:too_large),
    do: Gettext.gettext(PhoenixKitWeb.Gettext, "File is too large.")

  def upload_error_message(:not_accepted),
    do: Gettext.gettext(PhoenixKitWeb.Gettext, "File type not accepted.")

  def upload_error_message(:too_many_files),
    do: Gettext.gettext(PhoenixKitWeb.Gettext, "Too many files.")

  def upload_error_message(other),
    do: Gettext.gettext(PhoenixKitWeb.Gettext, "Upload error: %{reason}", reason: inspect(other))

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
          Gettext.gettext(PhoenixKitWeb.Gettext, "Selected image could not be loaded.")
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

  defp ensure_folder(socket, scope) do
    st = state(socket, scope)

    case st.folder_uuid do
      uuid when is_binary(uuid) ->
        {:ok, uuid, socket}

      _ ->
        case folder_name_for(st.resource) do
          {:ok, name} -> find_or_create_folder(socket, scope, name)
          :pending -> create_pending_folder(socket, scope)
        end
    end
  end

  defp find_or_create_folder(socket, scope, folder_name) do
    case find_folder_by_name(folder_name) do
      %{uuid: uuid} ->
        socket = update_scope(socket, scope, &Map.put(&1, :folder_uuid, uuid))
        {:ok, uuid, socket}

      nil ->
        create_folder(socket, scope, folder_name)
    end
  end

  defp create_pending_folder(socket, scope) do
    create_folder(socket, scope, "location-attachment-pending-#{Ecto.UUID.generate()}")
  end

  defp create_folder(socket, scope, folder_name) do
    user_uuid = current_user_uuid(socket)

    case Storage.create_folder(%{name: folder_name, user_uuid: user_uuid}) do
      {:ok, folder} ->
        socket = update_scope(socket, scope, &Map.put(&1, :folder_uuid, folder.uuid))
        {:ok, folder.uuid, socket}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_folder_by_name(name) when is_binary(name) do
    from(f in PhoenixKit.Modules.Storage.Folder,
      where: f.name == ^name and is_nil(f.parent_uuid),
      limit: 1
    )
    |> PhoenixKit.RepoHelper.repo().one()
  rescue
    error ->
      Logger.warning("find_folder_by_name failed for #{name}: #{inspect(error)}")
      nil
  end

  # ═══════════════════════════════════════════════════════════════════
  # Internals — file list query + storage I/O
  # ═══════════════════════════════════════════════════════════════════

  defp compute_files_list(nil, _featured_file), do: []

  defp compute_files_list(folder_uuid, featured_file) do
    folder_files = list_files_in_folder(folder_uuid)

    case featured_file do
      nil ->
        folder_files

      %{uuid: featured_uuid} ->
        if Enum.any?(folder_files, &(&1.uuid == featured_uuid)),
          do: folder_files,
          else: [featured_file | folder_files]
    end
  end

  defp list_files_in_folder(folder_uuid) do
    linked_subq =
      from(fl in FolderLink,
        where: fl.folder_uuid == ^folder_uuid,
        select: fl.file_uuid
      )

    from(f in File,
      where:
        (f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked_subq)) and
          f.status != "trashed",
      order_by: [asc: f.inserted_at],
      limit: @files_grid_limit
    )
    |> PhoenixKit.RepoHelper.repo().all()
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

  defp current_user_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  defp do_detach(_uuid, nil), do: :ok

  defp do_detach(file_uuid, folder_uuid) do
    case Storage.get_file(file_uuid) do
      nil -> :ok
      %File{folder_uuid: ^folder_uuid} = file -> detach_home(file)
      %File{} = file -> detach_link(file.uuid, folder_uuid)
    end
  end

  defp detach_home(file) do
    repo = PhoenixKit.RepoHelper.repo()

    case list_links(file.uuid) do
      [] ->
        case soft_trash_file(file) do
          {:ok, _} -> :ok
          err -> err
        end

      [%FolderLink{} = link | _rest] ->
        repo.transaction(fn ->
          file
          |> Ecto.Changeset.change(%{folder_uuid: link.folder_uuid})
          |> repo.update!()

          repo.delete!(link)
        end)
        |> case do
          {:ok, _} -> :ok
          err -> err
        end
    end
  end

  defp soft_trash_file(%File{} = file) do
    file
    |> Ecto.Changeset.change(%{
      status: "trashed",
      trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> PhoenixKit.RepoHelper.repo().update()
  end

  defp detach_link(file_uuid, folder_uuid) do
    from(fl in FolderLink,
      where: fl.file_uuid == ^file_uuid and fl.folder_uuid == ^folder_uuid
    )
    |> PhoenixKit.RepoHelper.repo().delete_all()

    :ok
  end

  defp list_links(file_uuid) do
    from(fl in FolderLink, where: fl.file_uuid == ^file_uuid)
    |> PhoenixKit.RepoHelper.repo().all()
  end

  defp store_upload(%{path: path}, entry, socket, folder_uuid) do
    user_uuid = current_user_uuid(socket)

    if is_nil(user_uuid) do
      {:ok, {:error, :no_user}}
    else
      file_checksum = UsersAuth.calculate_file_hash(path)
      ext = entry.client_name |> Path.extname() |> String.trim_leading(".") |> String.downcase()
      file_type = file_type_from_mime(entry.client_type)

      case Storage.store_file_in_buckets(
             path,
             file_type,
             user_uuid,
             file_checksum,
             ext,
             entry.client_name
           ) do
        {:ok, file} ->
          _ = assign_file_to_folder(file, folder_uuid)
          {:ok, {:ok, file}}

        {:ok, file, :duplicate} ->
          _ = assign_file_to_folder(file, folder_uuid)
          {:ok, {:ok, file}}

        {:error, reason} ->
          {:ok, {:error, reason}}
      end
    end
  end

  defp assign_file_to_folder(%{folder_uuid: current}, folder_uuid) when current == folder_uuid,
    do: :ok

  defp assign_file_to_folder(%File{folder_uuid: nil} = file, folder_uuid) do
    file
    |> Ecto.Changeset.change(%{folder_uuid: folder_uuid})
    |> PhoenixKit.RepoHelper.repo().update()
  end

  defp assign_file_to_folder(%File{uuid: file_uuid}, folder_uuid) when is_binary(folder_uuid) do
    %FolderLink{}
    |> FolderLink.changeset(%{folder_uuid: folder_uuid, file_uuid: file_uuid})
    |> PhoenixKit.RepoHelper.repo().insert(
      on_conflict: :nothing,
      conflict_target: [:folder_uuid, :file_uuid]
    )
  end

  defp put_upload_error(socket, entry, reason) do
    Logger.warning("Attachment upload failed for #{entry.client_name}: #{inspect(reason)}")

    put_flash(
      socket,
      :error,
      Gettext.gettext(PhoenixKitWeb.Gettext, "Upload failed for %{name}.",
        name: entry.client_name
      )
    )
  end

  @document_mimes ~w(
    application/pdf
    application/msword
    application/vnd.openxmlformats-officedocument.wordprocessingml.document
    application/vnd.ms-excel
    application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
  )

  defp file_type_from_mime(mime) when mime in [nil, ""], do: "other"

  defp file_type_from_mime(mime) when is_binary(mime) do
    file_type_from_prefix(mime) ||
      file_type_from_exact(mime) ||
      file_type_from_keyword(mime) ||
      "other"
  end

  defp file_type_from_prefix("image/" <> _), do: "image"
  defp file_type_from_prefix("video/" <> _), do: "video"
  defp file_type_from_prefix("audio/" <> _), do: "audio"
  defp file_type_from_prefix("text/" <> _), do: "document"
  defp file_type_from_prefix(_), do: nil

  defp file_type_from_exact(mime) when mime in @document_mimes, do: "document"
  defp file_type_from_exact(_), do: nil

  defp file_type_from_keyword(mime) do
    if String.contains?(mime, "zip") or String.contains?(mime, "archive") do
      "archive"
    end
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
