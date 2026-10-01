defmodule PhoenixKitLocations.Web.Components.SpaceTree do
  @moduledoc """
  Recursive tree of a Location's `Space` hierarchy (floors, rooms, zones,
  sections, aisles, shelves) — an adaptation of
  `PhoenixKitWeb.Components.FolderExplorer.folder_tree_node/1` for
  `PhoenixKitLocations.Spaces.list_tree/1` nodes. Simplified relative to
  that model: no desktop-only fixed-width sidebar and no drag/drop or
  connector-line CSS — a single full-width column.

  ## Node shape

  `Spaces.list_tree/1` returns a plain list of `%Space{}` structs — each
  node carries its children directly under the schema's own `:children`
  association key (`Map.put(space, :children, ...)`), **not** wrapped in
  a `%{space: ..., children: ...}` envelope the way `FolderExplorer`'s
  `%{folder: ..., children: ...}` nodes are. Every field on a node is
  read straight off the struct: `node.kind`, `node.uuid`, `node.name`,
  `node.status`, `node.children` — never `node.space.kind`.

  ## Ownership model

  Pure presentation. The consumer owns all state (`expanded` MapSet,
  `selected_uuid`, `renaming_uuid`/`renaming_text`) — every interactive
  control fires back via `phx-target={@myself}`. Pass `myself={nil}` when
  the consumer is a plain LiveView rather than a LiveComponent;
  `phx-target` is then simply omitted, routing the event to the LiveView
  itself.

  Reorder (▲/▼) and rename are the only actions this component treats as
  "immediate" — they fire their event straight away. Everything else
  (creating a space, editing its other fields) is left to a form panel
  owned by the consumer. `delete_space` is deliberately *not* immediate
  either — no `data-confirm` here, since a hard delete cascades to the
  whole subtree: the event just asks the consumer to open its own
  confirmation modal (with the descendant count), which is the only
  place the actual delete is triggered from.

  Consumers implement:

      toggle_space_node, select_space,
      start_rename_space, rename_space_input, rename_space, cancel_rename_space,
      move_space_up, move_space_down, open_add_child,
      delete_space (opens a confirmation — does not delete by itself),
      open_add_root (the "+ Add root space" button in `space_tree/1`)

  ## Picker mode

  `show_actions={false}` hides the rename/reorder/add-child/delete
  affordances on every node (and the wrapper's "+ Add root space"
  button) and leaves only click-to-select + expand/collapse — the shape
  `PlacePicker` (v0.5) needs to reuse this same tree read-only.

  ## Usage

      <.space_tree
        tree={@tree}
        expanded={@expanded}
        selected_uuid={@selected_uuid}
        myself={nil}
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitLocations.Gettext

  import PhoenixKitWeb.Components.Core.Badge, only: [status_badge: 1]
  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.EmptyState, only: [empty_state: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitLocations.Schemas.Space

  # ──────────────────────────────────────────────────────────────
  # Top-level component
  # ──────────────────────────────────────────────────────────────

  attr(:tree, :list, required: true, doc: "Root-level nodes from `Spaces.list_tree/1`.")
  attr(:expanded, :any, required: true, doc: "MapSet of expanded node UUIDs.")
  attr(:selected_uuid, :string, default: nil)
  attr(:renaming_uuid, :string, default: nil)
  attr(:renaming_text, :string, default: "")

  attr(:myself, :any,
    default: nil,
    doc: "LiveComponent CID, or nil when the consumer is a plain LiveView."
  )

  attr(:on_select, :string, default: "select_space")
  attr(:on_toggle, :string, default: "toggle_space_node")
  attr(:on_add_root, :string, default: "open_add_root")

  attr(:show_actions, :boolean,
    default: true,
    doc: "false switches every node into picker/read-only mode (select + expand only)."
  )

  def space_tree(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <ul :if={@tree != []} class="flex flex-col gap-0.5">
        <.space_tree_node
          :for={{node, idx} <- Enum.with_index(@tree)}
          node={node}
          expanded={@expanded}
          selected_uuid={@selected_uuid}
          renaming_uuid={@renaming_uuid}
          renaming_text={@renaming_text}
          depth={0}
          is_first={idx == 0}
          is_last={idx == length(@tree) - 1}
          myself={@myself}
          on_select={@on_select}
          on_toggle={@on_toggle}
          show_actions={@show_actions}
        />
      </ul>

      <.empty_state
        :if={@tree == []}
        icon="hero-squares-2x2"
        title={gettext("No spaces yet.")}
        class="py-6"
      />

      <.button
        :if={@show_actions}
        type="button"
        variant="ghost"
        size="sm"
        class="self-start"
        phx-click={@on_add_root}
        phx-target={@myself}
      >
        <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Add root space")}
      </.button>
    </div>
    """
  end

  # ──────────────────────────────────────────────────────────────
  # Recursive tree node
  # ──────────────────────────────────────────────────────────────

  attr(:node, :map,
    required: true,
    doc: "A `%Space{}` struct with a nested `:children` list (see moduledoc)."
  )

  attr(:expanded, :any, required: true)
  attr(:selected_uuid, :string, default: nil)
  attr(:renaming_uuid, :string, default: nil)
  attr(:renaming_text, :string, default: "")
  attr(:depth, :integer, default: 0)
  attr(:is_first, :boolean, default: true, doc: "Hides the move-up button when true.")
  attr(:is_last, :boolean, default: true, doc: "Hides the move-down button when true.")
  attr(:myself, :any, default: nil)

  attr(:on_select, :string, default: "select_space")
  attr(:on_toggle, :string, default: "toggle_space_node")

  attr(:show_actions, :boolean,
    default: true,
    doc: "false hides pencil/reorder/add-child/delete — click-to-select + expand only."
  )

  def space_tree_node(assigns) do
    assigns =
      assigns
      |> assign(:is_selected, assigns.selected_uuid == assigns.node.uuid)
      |> assign(:is_expanded, MapSet.member?(assigns.expanded, assigns.node.uuid))
      |> assign(:has_children, assigns.node.children != [])
      |> assign(:is_renaming, assigns.show_actions and assigns.renaming_uuid == assigns.node.uuid)

    ~H"""
    <li data-depth={@depth}>
      <%!--
        Whole row is clickable to select the node. LiveView resolves a
        click to the closest `phx-click` element, so the chevron and (when
        `show_actions`) the action buttons handle their own clicks — only
        clicks elsewhere on the row fall through to `@on_select`. Selection
        is suppressed while the inline rename form is open, same as
        `FolderExplorer.folder_tree_node/1`.
      --%>
      <div
        phx-click={!@is_renaming && @on_select}
        phx-target={@myself}
        phx-value-uuid={@node.uuid}
        class={[
          "flex items-center gap-1 rounded-lg px-1.5 py-1 transition-colors",
          !@is_renaming && "cursor-pointer",
          if(@is_selected, do: "bg-primary/10 font-semibold", else: "hover:bg-base-200")
        ]}
      >
        <button
          :if={@has_children}
          type="button"
          phx-click={@on_toggle}
          phx-target={@myself}
          phx-value-uuid={@node.uuid}
          class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5 shrink-0"
        >
          <.icon
            name={if @is_expanded, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
            class="w-4 h-4 text-base-content/40"
          />
        </button>
        <span :if={!@has_children} class="w-5 shrink-0"></span>

        <.icon name={Space.kind_icon(@node.kind)} class="w-4 h-4 shrink-0 text-base-content/60" />

        <%= if @is_renaming do %>
          <%!-- Inline rename form — Enter (form submit) commits, Escape or
               blur cancels. Mirrors `FolderExplorer.folder_tree_node/1`'s
               rename form exactly (including the `SelectOnMount` hook that
               selects the existing text so typing replaces it). --%>
          <form
            phx-submit="rename_space"
            phx-change="rename_space_input"
            phx-target={@myself}
            class="flex flex-1 min-w-0 items-center gap-1.5"
          >
            <input type="hidden" name="uuid" value={@node.uuid} />
            <input
              type="text"
              name="name"
              id={"rename-space-#{@node.uuid}"}
              value={@renaming_text}
              class="bg-base-100 text-sm rounded px-1.5 py-0 flex-1 min-w-0 border border-primary/60 focus:outline-none focus:border-primary"
              phx-hook="SelectOnMount"
              required
              phx-keydown="cancel_rename_space"
              phx-key="Escape"
              phx-blur="cancel_rename_space"
              phx-target={@myself}
              phx-debounce="50"
            />
          </form>
        <% else %>
          <span class="flex-1 min-w-0 truncate text-sm" title={@node.name}>{@node.name}</span>
          <span class="badge badge-sm badge-ghost shrink-0">{Space.kind_label(@node.kind)}</span>
          <.status_badge
            :if={@node.status == "inactive"}
            status="inactive"
            label={gettext("Inactive")}
            class="shrink-0"
          />
        <% end %>

        <div :if={@show_actions and !@is_renaming} class="flex items-center gap-0.5 shrink-0">
          <button
            :if={!@is_first}
            type="button"
            phx-click="move_space_up"
            phx-disable-with="…"
            phx-target={@myself}
            phx-value-uuid={@node.uuid}
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5"
            title={gettext("Move up")}
          >
            <.icon name="hero-chevron-up-mini" class="w-4 h-4" />
          </button>
          <button
            :if={!@is_last}
            type="button"
            phx-click="move_space_down"
            phx-disable-with="…"
            phx-target={@myself}
            phx-value-uuid={@node.uuid}
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5"
            title={gettext("Move down")}
          >
            <.icon name="hero-chevron-down-mini" class="w-4 h-4" />
          </button>
          <button
            type="button"
            phx-click="start_rename_space"
            phx-target={@myself}
            phx-value-uuid={@node.uuid}
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5"
            title={gettext("Rename")}
          >
            <.icon name="hero-pencil" class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            phx-click="open_add_child"
            phx-target={@myself}
            phx-value-parent_uuid={@node.uuid}
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5"
            title={gettext("Add child")}
          >
            <.icon name="hero-plus" class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            phx-click="delete_space"
            phx-target={@myself}
            phx-value-uuid={@node.uuid}
            class="btn btn-ghost btn-xs p-0 min-h-0 h-5 w-5 text-error"
            title={gettext("Delete")}
          >
            <.icon name="hero-trash" class="w-3.5 h-3.5" />
          </button>
        </div>
      </div>

      <ul :if={@has_children and @is_expanded} class="flex flex-col gap-0.5 ml-6">
        <.space_tree_node
          :for={{child, idx} <- Enum.with_index(@node.children)}
          node={child}
          expanded={@expanded}
          selected_uuid={@selected_uuid}
          renaming_uuid={@renaming_uuid}
          renaming_text={@renaming_text}
          depth={@depth + 1}
          is_first={idx == 0}
          is_last={idx == length(@node.children) - 1}
          myself={@myself}
          on_select={@on_select}
          on_toggle={@on_toggle}
          show_actions={@show_actions}
        />
      </ul>
    </li>
    """
  end
end
