defmodule PhoenixKitLocations.Policy do
  @moduledoc """
  Who may see and change which locations: one server-side module every
  LiveView routes through (controls are hidden AND actions re-checked), in the
  shape `phoenix_kit_bookings` established.

  ## The permission model

  Core's sub-permission semantics (a sub-permission implies its base) set the
  orientation:

    * **base `"locations"`** opens the Locations admin pages, scoped to the
      locations owned by the user or by the user's organization: the list,
      create, edit, delete and Structure. This is the key an operator grants so
      users manage their own (or their company's) sites.
    * **sub `"locations.manage_all"`** adds every location (owned or global),
      ownership assignment, internal notes, attachments and the Types pages.
      Core auto-grants every sub-permission to Admin at boot; Owner holds all
      keys.

  A scope with neither `manage_all` nor a user sees nothing.

  ## Organizations

  In core a person account belongs to at most one organization account
  (`organization_uuid` on the user row), and there are no roles inside an
  organization. So without `manage_all` a user acts on locations owned by any
  of `owner_uuids/1`: their own account and their organization. Every member of
  an organization sees and manages the organization's locations equally, and a
  location a member creates belongs to the organization (`new_owner_uuid/1`), so
  teammates share it. Leaving the organization removes that access with no
  change here.
  """

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.Location

  @manage_all "locations.manage_all"

  @doc "The composed sub-permission key for site-wide location management."
  @spec manage_all_key() :: String.t()
  def manage_all_key, do: @manage_all

  @doc "True when the scope holds `locations.manage_all` (and the module is enabled)."
  @spec manage_all?(Scope.t() | nil) :: boolean()
  def manage_all?(%Scope{} = scope), do: Scope.can?(scope, @manage_all)
  def manage_all?(_scope), do: false

  @doc "The acting user's uuid, or `nil`."
  @spec user_uuid(Scope.t() | nil) :: String.t() | nil
  def user_uuid(%Scope{user: %{uuid: uuid}}) when is_binary(uuid), do: uuid
  def user_uuid(_scope), do: nil

  @doc """
  The owners whose locations a user acts on without `manage_all`: the user's
  own account, plus their organization account when they belong to one.

  Accepts a scope or a user (anything with `:uuid` and an optional
  `:organization_uuid`), so host code outside a LiveView can resolve the same
  set. `[]` without a user.
  """
  @spec owner_uuids(Scope.t() | map() | nil) :: [String.t()]
  def owner_uuids(%Scope{user: user}), do: owner_uuids(user)

  def owner_uuids(%{uuid: uuid} = user) when is_binary(uuid) do
    case Map.get(user, :organization_uuid) do
      org_uuid when is_binary(org_uuid) and org_uuid != uuid -> [uuid, org_uuid]
      _ -> [uuid]
    end
  end

  def owner_uuids(_scope_or_user), do: []

  @doc """
  The owner a location created by this user gets when they don't hold
  `manage_all`: their organization when they belong to one (so teammates share
  it), otherwise their own account. `nil` without a user.
  """
  @spec new_owner_uuid(Scope.t() | map() | nil) :: String.t() | nil
  def new_owner_uuid(scope_or_user) do
    case owner_uuids(scope_or_user) do
      [_user_uuid, org_uuid] -> org_uuid
      [user_uuid] -> user_uuid
      [] -> nil
    end
  end

  @doc """
  The locations the scope may see, ordered by name: every location for
  `manage_all`, otherwise only those owned by `owner_uuids/1`, and none without
  a user.

  `opts` are `Locations.list_locations/1` filters. An `owner_uuid:` among them
  is honoured only for `manage_all`; everyone else is pinned to their owners.
  """
  @spec list_locations(Scope.t() | nil, Locations.list_locations_opts()) :: [Location.t()]
  def list_locations(scope, opts \\ []) do
    if manage_all?(scope) do
      Locations.list_locations(opts)
    else
      case owner_uuids(scope) do
        [] -> []
        owners -> Locations.list_locations(Keyword.put(opts, :owner_uuid, owners))
      end
    end
  end

  @doc """
  Resolves one location the scope may act on, or `nil`: any location for
  `manage_all`, otherwise only one owned by `owner_uuids/1`. A malformed uuid
  is `nil`, never a raise.
  """
  @spec get_location(Scope.t() | nil, String.t() | nil) :: Location.t() | nil
  def get_location(scope, uuid) do
    if manage_all?(scope) do
      case is_binary(uuid) and Ecto.UUID.cast(uuid) do
        {:ok, _} -> Locations.get_location(uuid)
        _ -> nil
      end
    else
      Locations.get_location_for_owner(uuid, owner_uuids(scope))
    end
  end

  @doc """
  The `Locations.find_similar_addresses/5` options for the scope: unrestricted
  for `manage_all`, otherwise the locations of `owner_uuids/1` only, so the
  duplicate-address warning can never name another account's location.
  """
  @spec similar_address_opts(Scope.t() | nil) :: keyword()
  def similar_address_opts(scope) do
    if manage_all?(scope), do: [], else: [owner_uuid: owner_uuids(scope)]
  end
end
