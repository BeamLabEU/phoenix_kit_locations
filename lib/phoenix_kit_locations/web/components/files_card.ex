defmodule PhoenixKitLocations.Web.Components.FilesCard do
  @moduledoc """
  Reusable Files + Featured Image card body. Renders the same UI
  for Location, floors, and rooms — each instance scoped by the
  `scope` attr, which is forwarded as `phx-value-scope` on every
  event button. The single shared upload config is owned by the
  parent LiveView; each dropzone here also sets `:active_upload_scope`
  on click so the upload routes to the right folder.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitLocations.Gettext

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.EmptyState, only: [empty_state: 1]
  import PhoenixKitWeb.Components.Core.FileUpload, only: [upload_entry_stats: 1]
  import PhoenixKitWeb.Components.Core.FormSection, only: [section_header: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitLocations.Attachments

  attr(:scope, :string, required: true)
  attr(:state, :map, required: true, doc: "Map from `Attachments.state/2`")
  attr(:uploads, :map, required: true)
  attr(:featured_subtitle, :string, default: nil)
  attr(:files_subtitle, :string, default: nil)
  attr(:remove_file_confirm, :string, default: nil)

  def files_card_body(assigns) do
    assigns =
      assigns
      |> Phoenix.Component.assign_new(:featured_subtitle, fn ->
        gettext("Shown alongside this item in listings.")
      end)
      |> Phoenix.Component.assign_new(:files_subtitle, fn ->
        gettext("Floor plans, brochures, certificates. Any file type is accepted.")
      end)
      |> Phoenix.Component.assign_new(:remove_file_confirm, fn ->
        gettext(
          "Remove this file? If it's not attached to any other resource, it will be moved to trash (admins can restore)."
        )
      end)

    ~H"""
    <div class="flex flex-col gap-0.5">
      <.section_header icon="hero-photo" title={gettext("Featured Image")} />
      <p class="text-xs text-base-content/50">{@featured_subtitle}</p>
    </div>

    <%= if @state.featured_image_file do %>
      <div class="flex items-center gap-4">
        <a
          href={URLSigner.signed_url(@state.featured_image_uuid, "original")}
          target="_blank"
          rel="noopener"
          class="shrink-0"
          title={gettext("Open original")}
        >
          <img
            src={URLSigner.signed_url(@state.featured_image_uuid, "thumbnail")}
            alt={@state.featured_image_file.original_file_name}
            class="w-24 h-24 rounded-md object-cover bg-base-200 border border-base-300"
          />
        </a>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium truncate">{@state.featured_image_file.original_file_name}</p>
          <p class="text-xs text-base-content/50">{Attachments.format_file_size(@state.featured_image_file.size)}</p>
        </div>
        <div class="flex flex-col gap-2">
          <.button
            type="button"
            variant="outline"
            size="sm"
            phx-click="open_featured_image_picker"
            phx-value-scope={@scope}
          >
            {gettext("Change")}
          </.button>
          <.button
            type="button"
            variant="ghost"
            size="sm"
            phx-click="clear_featured_image"
            phx-value-scope={@scope}
            phx-disable-with={gettext("Removing...")}
          >
            {gettext("Remove")}
          </.button>
        </div>
      </div>
    <% else %>
      <div class="flex items-center justify-between py-4 border border-dashed border-base-300 rounded-md px-4">
        <div class="flex items-center gap-3 text-base-content/60">
          <.icon name="hero-photo" class="w-6 h-6" />
          <span class="text-sm">{gettext("No featured image set.")}</span>
        </div>
        <.button
          type="button"
          size="sm"
          phx-click="open_featured_image_picker"
          phx-value-scope={@scope}
        >
          <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Set featured image")}
        </.button>
      </div>
    <% end %>

    <div class="flex flex-col gap-0.5">
      <.section_header icon="hero-paper-clip" title={gettext("Attached Files")}>
        <:actions :if={@state.files != []}>
          <span class="badge badge-sm badge-ghost">{length(@state.files)}</span>
        </:actions>
      </.section_header>
      <p class="text-xs text-base-content/50">{@files_subtitle}</p>
    </div>

    <%!-- Dropzone: phx-click covers the click path; the hook
         (`priv/static/assets/phoenix_kit_locations.js`) sets the scope on
         `dragenter` so drag-and-drop uploads route to the right folder
         without a prior click. The label also forwards clicks to the
         hidden <input type=file>. --%>
    <label
      id={"pk-locations-dropzone-#{@scope}"}
      for={@uploads.attachment_files.ref}
      class="flex flex-col items-center justify-center gap-2 py-6 border-2 border-dashed border-base-300 rounded-md bg-base-200/20 hover:bg-base-200/40 transition-colors cursor-pointer"
      phx-click="set_active_upload_scope"
      phx-value-scope={@scope}
      phx-drop-target={@uploads.attachment_files.ref}
      phx-hook="PhoenixKitLocationsUploadScope"
      data-scope={@scope}
    >
      <.icon name="hero-cloud-arrow-up" class="w-8 h-8 text-base-content/40" />
      <div class="text-sm text-base-content/60">
        <span class="font-medium text-primary">{gettext("Click to upload")}</span>
        <span>{gettext(" or drag & drop")}</span>
      </div>
      <.live_file_input upload={@uploads.attachment_files} class="hidden" />
    </label>

    <div :if={@uploads.attachment_files.entries != []} class="flex flex-col gap-2">
      <div
        :for={entry <- @uploads.attachment_files.entries}
        class="flex items-center gap-3 rounded-md border border-base-300 bg-base-100 p-2"
      >
        <.icon name="hero-cloud-arrow-up" class="w-4 h-4 text-base-content/60 shrink-0" />
        <div class="flex-1 min-w-0">
          <p class="text-sm truncate">{entry.client_name}</p>
          <progress class="progress progress-primary w-full h-1 mt-1" value={entry.progress} max="100"></progress>
          <.upload_entry_stats entry={entry} />
        </div>
        <span class="text-xs text-base-content/50 tabular-nums">{entry.progress}%</span>
        <.button
          type="button"
          variant="ghost"
          size="xs"
          class="btn-square"
          phx-click="cancel_upload"
          phx-value-ref={entry.ref}
          title={gettext("Cancel")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </.button>
      </div>
    </div>

    <p :for={err <- upload_errors(@uploads.attachment_files)} class="text-xs text-error">
      {Attachments.upload_error_message(err)}
    </p>

    <%= if @state.files == [] do %>
      <.empty_state
        icon="hero-paper-clip"
        title={gettext("No files attached yet.")}
        class="py-10 border border-dashed border-base-300 rounded-md"
      />
    <% else %>
      <ul class="grid grid-cols-1 md:grid-cols-2 gap-3">
        <li
          :for={file <- @state.files}
          class="flex items-center gap-3 rounded-md border border-base-300 bg-base-200/30 p-3"
        >
          <%= if file.file_type == "image" do %>
            <a
              href={URLSigner.signed_url(file.uuid, "original")}
              target="_blank"
              rel="noopener"
              class="shrink-0"
            >
              <img
                src={URLSigner.signed_url(file.uuid, "thumbnail")}
                alt={file.original_file_name}
                class="w-14 h-14 rounded object-cover bg-base-200 border border-base-300"
              />
            </a>
          <% else %>
            <a
              href={URLSigner.signed_url(file.uuid, "original")}
              target="_blank"
              rel="noopener"
              class="shrink-0 flex items-center justify-center w-14 h-14 rounded bg-base-200 border border-base-300 text-base-content/60"
              title={gettext("Download")}
            >
              <.icon name={Attachments.file_icon(file)} class="w-6 h-6" />
            </a>
          <% end %>
          <div class="flex-1 min-w-0">
            <p class="text-sm font-medium truncate" title={file.original_file_name}>
              {file.original_file_name}
            </p>
            <p class="text-xs text-base-content/50">
              {Attachments.format_file_size(file.size)} · {file.file_type}
            </p>
          </div>
          <.button
            type="button"
            variant="ghost"
            size="xs"
            class="btn-square"
            phx-click="remove_file"
            phx-value-scope={@scope}
            phx-value-uuid={file.uuid}
            phx-disable-with={gettext("Removing...")}
            data-confirm={@remove_file_confirm}
            title={gettext("Remove")}
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </.button>
        </li>
      </ul>
    <% end %>

    """
  end
end
