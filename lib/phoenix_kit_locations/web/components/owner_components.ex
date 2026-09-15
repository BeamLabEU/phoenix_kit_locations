defmodule PhoenixKitLocations.Web.Components.OwnerComponents do
  @moduledoc """
  Admin-side ownership UI for the location list and form: the
  All / Global / Owned filter, owner labels, and the owner picker card.

  Pure presentation. The picker's events (`search_owner`, `pick_owner`,
  `clear_owner`) are handled by the hosting LiveView. The picker renders its
  own small search form, so it must sit outside `#location-form` (forms
  cannot nest).
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitLocations.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitLocations.Paths

  @doc "Title for the owner column."
  @spec owner_column_title() :: String.t()
  def owner_column_title, do: gettext("Owner")

  @doc "An owner's display text: their email from `emails`, or \"Global\" for `nil`."
  @spec owner_text(String.t() | nil, %{optional(String.t()) => String.t()}) :: String.t()
  def owner_text(nil, _emails), do: gettext("Global")
  def owner_text(owner_uuid, emails), do: Map.get(emails, owner_uuid, owner_uuid)

  @doc "Parses the list page's `?owner=` param into a filter key."
  @spec parse_owner_filter(String.t() | nil) :: :all | :global | :owned
  def parse_owner_filter("global"), do: :global
  def parse_owner_filter("owned"), do: :owned
  def parse_owner_filter(_), do: :all

  @doc "The `Locations.list_locations/1` options for a filter key."
  @spec owner_filter_opts(:all | :global | :owned) :: keyword()
  def owner_filter_opts(:global), do: [owner_uuid: nil]
  def owner_filter_opts(:owned), do: [owner_uuid: :any]
  def owner_filter_opts(:all), do: []

  attr(:active, :atom, required: true, doc: "`:all`, `:global` or `:owned`")

  @doc "All / Global / Owned segmented filter, patching `?owner=` on the list page."
  def owner_filter(assigns) do
    assigns =
      assign(assigns, :options, [
        {:all, gettext("All"), Paths.index()},
        {:global, gettext("Global"), "#{Paths.index()}?owner=global"},
        {:owned, gettext("Owned"), "#{Paths.index()}?owner=owned"}
      ])

    ~H"""
    <div id="owner-filter" class="join" role="group" aria-label={gettext("Filter by owner")}>
      <.link
        :for={{key, label, path} <- @options}
        id={"owner-filter-#{key}"}
        patch={path}
        class={["btn btn-sm join-item", if(@active == key, do: "btn-active btn-primary", else: "btn-ghost")]}
        aria-current={if @active == key, do: "true"}
      >
        {label}
      </.link>
    </div>
    """
  end

  attr(:owner, :map, default: nil, doc: "`%{uuid: _, email: _}` or `nil`")
  attr(:query, :string, default: "")
  attr(:matches, :list, default: [])

  @doc "Owner card for the admin location form. The chosen owner applies on save."
  def owner_picker_card(assigns) do
    ~H"""
    <div id="location-owner-card" class="card bg-base-100 shadow-lg mb-6">
      <div class="card-body flex flex-col gap-3">
        <h2 class="text-base font-semibold text-base-content/80 flex items-center gap-2">
          <.icon name="hero-user-circle" class="h-4 w-4" />
          {gettext("Owner")}
        </h2>
        <p class="text-sm text-base-content/50 -mt-1">
          {gettext("A location with an owner is private to that account; without one it is global. The change applies when you save.")}
        </p>

        <div class="flex flex-wrap items-center gap-2">
          <span :if={@owner} id="location-owner-current" class="badge badge-lg badge-primary gap-1">
            <.icon name="hero-user" class="h-3.5 w-3.5" />
            {@owner.email}
          </span>
          <button :if={@owner} type="button" phx-click="clear_owner" class="btn btn-ghost btn-xs">
            {gettext("Remove owner")}
          </button>
          <span :if={!@owner} id="location-owner-current" class="badge badge-lg badge-ghost">
            {gettext("No owner (global)")}
          </span>
        </div>

        <form id="owner-search-form" phx-change="search_owner" phx-submit="search_owner">
          <input
            type="text"
            name="owner_search"
            value={@query}
            placeholder={gettext("Search users by email or name…")}
            phx-debounce="300"
            autocomplete="off"
            class="input input-sm w-full"
          />
        </form>

        <ul :if={@matches != []} id="owner-matches" class="menu bg-base-200 rounded-box w-full">
          <li :for={user <- @matches}>
            <button type="button" phx-click="pick_owner" phx-value-uuid={user.uuid}>
              {user.email}
            </button>
          </li>
        </ul>

        <p
          :if={@matches == [] and String.length(String.trim(@query)) >= 2}
          class="text-sm text-base-content/50"
        >
          {gettext("No users found.")}
        </p>
      </div>
    </div>
    """
  end
end
