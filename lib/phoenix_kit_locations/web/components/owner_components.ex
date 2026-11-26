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

  @typedoc """
  What the UI shows for an owner account: `name` is the organization's name,
  the person's name, their username or (last) their email; `email` is an
  address a human can use, so a managed organization's placeholder login
  address never appears; `kind` tells a person from an organization.
  """
  @type owner :: %{
          uuid: String.t(),
          name: String.t(),
          email: String.t() | nil,
          kind: :person | :organization
        }

  @doc "Builds the display map for an owner from a core user row."
  @spec owner_info(map()) :: owner()
  def owner_info(%{uuid: uuid} = user) do
    email = shown_email(user)

    %{
      uuid: to_string(uuid),
      name:
        first_present([account_name(user), Map.get(user, :username), email]) || to_string(uuid),
      email: email,
      kind: if(Map.get(user, :account_type) == "organization", do: :organization, else: :person)
    }
  end

  @doc "The display map for an owner whose account could not be loaded."
  @spec unknown_owner(String.t()) :: owner()
  def unknown_owner(uuid), do: %{uuid: uuid, name: uuid, email: nil, kind: :person}

  # A managed organization signs in through its members; its `email` column
  # holds a generated `org-<uuid>@organization.invalid`, never shown.
  defp shown_email(%{managed_by_members: true} = user),
    do: blank_to_nil(Map.get(user, :contact_email))

  defp shown_email(user), do: blank_to_nil(Map.get(user, :email))

  defp account_name(%{account_type: "organization"} = user), do: Map.get(user, :organization_name)

  defp account_name(user) do
    [Map.get(user, :first_name), Map.get(user, :last_name)]
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp first_present(values), do: Enum.find_value(values, &blank_to_nil/1)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  @doc "The heroicon for an owner kind."
  @spec owner_icon(:person | :organization) :: String.t()
  def owner_icon(:organization), do: "hero-building-office-2"
  def owner_icon(_kind), do: "hero-user"

  @doc "The translated word for an owner kind."
  @spec owner_kind_label(:person | :organization) :: String.t()
  def owner_kind_label(:organization), do: gettext("Organization")
  def owner_kind_label(_kind), do: gettext("User")

  @doc "An owner's display text: their name from `owners`, or \"Global\" for `nil`."
  @spec owner_text(String.t() | nil, %{optional(String.t()) => owner()}) :: String.t()
  def owner_text(nil, _owners), do: gettext("Global")

  def owner_text(owner_uuid, owners) do
    case Map.get(owners, owner_uuid) do
      %{name: name} -> name
      nil -> owner_uuid
    end
  end

  attr(:owner_uuid, :string, default: nil)
  attr(:owners, :map, required: true, doc: "uuid => `t:owner/0`")

  @doc "The owner cell of the list: kind icon and name, the email as a tooltip."
  def owner_label(assigns) do
    assigns =
      assign(assigns, :owner, assigns.owner_uuid && Map.get(assigns.owners, assigns.owner_uuid))

    ~H"""
    <span :if={!@owner_uuid} class="text-base-content/40">{gettext("Global")}</span>
    <span :if={@owner_uuid && !@owner}>{@owner_uuid}</span>
    <span :if={@owner} class="inline-flex items-center gap-1.5" title={@owner.email}>
      <.icon name={owner_icon(@owner.kind)} class="h-4 w-4 shrink-0 text-base-content/50" />
      <span class="sr-only">{owner_kind_label(@owner.kind)}:</span>
      {@owner.name}
    </span>
    """
  end

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

  attr(:owner, :map, default: nil, doc: "`t:owner/0` or `nil`")

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

      <div :if={@owner} id="location-owner-current" class="flex items-center gap-3 rounded-box border border-base-300 p-3">
        <.icon name={owner_icon(@owner.kind)} class="h-6 w-6 shrink-0 text-primary" />
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-medium truncate">{@owner.name}</span>
            <span class="badge badge-sm badge-ghost">{owner_kind_label(@owner.kind)}</span>
          </div>
          <div :if={@owner.email && @owner.email != @owner.name} class="text-sm text-base-content/60 truncate">
            {@owner.email}
          </div>
        </div>
        <.button type="button" variant="ghost" size="xs" phx-click="clear_owner">
          {gettext("Remove owner")}
        </.button>
      </div>
      <div :if={!@owner} id="location-owner-current">
        <span class="badge badge-lg badge-ghost">{gettext("No owner (global)")}</span>
      </div>

      <.search_picker
        id="owner-search"
        dropdown_id="owner-dropdown"
        search_event="search_owner"
        results_event="owner_results"
        pick_event="pick_owner"
        staged_event="owner_staged"
        placeholder={gettext("Search users and organizations by name or email…")}
        class="input input-sm w-full"
        row_layout="stacked"
        search_on_focus
        close_on_pick
        searching_label={gettext("Searching…")}
        more_label={gettext("Load more")}
        loading_more_label={gettext("Loading…")}
        no_matches_label={gettext("No users or organizations found.")}
      />
    </.form_section>
    """
  end

  @doc """
  Rows for the owner picker's `owner_results` push: the account's name as the
  label, with its kind and (when it has a usable one) its email underneath.
  """
  @spec owner_picker_rows([owner()]) :: [map()]
  def owner_picker_rows(owners) do
    Enum.map(owners, fn owner ->
      sublabel =
        [owner_kind_label(owner.kind), owner.email != owner.name && owner.email]
        |> Enum.filter(& &1)
        |> Enum.join(" · ")

      %{
        kind: to_string(owner.kind),
        uuid: owner.uuid,
        label: owner.name,
        sublabel: sublabel,
        icon: owner_icon(owner.kind)
      }
    end)
  end
end
