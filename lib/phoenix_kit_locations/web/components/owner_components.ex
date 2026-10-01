defmodule PhoenixKitLocations.Web.Components.OwnerComponents do
  @moduledoc """
  Admin-side ownership UI for the location list and form: the
  All / Global / Owned filter, owner labels, and the owner picker card.

  Pure presentation. The picker's events (`search_owner`, `pick_owner`,
  `clear_owner`) are handled by the hosting LiveView.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitLocations.Gettext

  import PhoenixKitWeb.Components.Core.Button, only: [button: 1]
  import PhoenixKitWeb.Components.Core.FormSection, only: [form_section: 1]
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.SearchPicker, only: [search_picker: 1]

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

  @doc """
  Owner card for the admin location form. The chosen owner applies on save.

  The search box is core's `<.search_picker>`: the hosting LiveView answers
  `search_owner` with `push_event("owner_results", …)` and confirms a
  `pick_owner` with `push_event("owner_staged", %{})`. Keep the card outside
  `#location-form`, so typing a search never fires the form's `phx-change`.
  """
  def owner_picker_card(assigns) do
    ~H"""
    <.form_section
      id="location-owner-card"
      title={gettext("Owner")}
      icon="hero-user-circle"
      class="mb-6"
      body_class="gap-3"
    >
      <:subtitle>
        {gettext("A location with an owner is private to that account; without one it is global. The change applies when you save.")}
      </:subtitle>

      <div class="flex flex-wrap items-center gap-2">
        <span :if={@owner} id="location-owner-current" class="badge badge-lg badge-primary gap-1">
          <.icon name="hero-user" class="h-3.5 w-3.5" />
          {@owner.email}
        </span>
        <.button :if={@owner} type="button" variant="ghost" size="xs" phx-click="clear_owner">
          {gettext("Remove owner")}
        </.button>
        <span :if={!@owner} id="location-owner-current" class="badge badge-lg badge-ghost">
          {gettext("No owner (global)")}
        </span>
      </div>

      <.search_picker
        id="owner-search"
        dropdown_id="owner-dropdown"
        search_event="search_owner"
        results_event="owner_results"
        pick_event="pick_owner"
        staged_event="owner_staged"
        placeholder={gettext("Search users by email or name…")}
        class="input input-sm w-full"
        searching_label={gettext("Searching…")}
        more_label={gettext("Load more")}
        loading_more_label={gettext("Loading…")}
        no_matches_label={gettext("No users found.")}
      />
    </.form_section>
    """
  end

  @doc """
  Rows for the owner picker's `owner_results` push: the user's email as the
  label and their name, when they have one, underneath.
  """
  @spec owner_picker_rows([map()]) :: [map()]
  def owner_picker_rows(users) do
    Enum.map(users, fn user ->
      name =
        [Map.get(user, :first_name), Map.get(user, :last_name)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" ")

      %{kind: "user", uuid: to_string(user.uuid), label: user.email, icon: "hero-user"}
      |> then(&if(name == "", do: &1, else: Map.put(&1, :sublabel, name)))
    end)
  end
end
