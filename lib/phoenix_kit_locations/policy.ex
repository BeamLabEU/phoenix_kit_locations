defmodule PhoenixKitLocations.Policy do
  @moduledoc """
  Who may see and change which locations: one server-side module every
  LiveView routes through (controls are hidden AND actions re-checked), in the
  shape `phoenix_kit_bookings` established.

  ## The permission model

  Core's sub-permission semantics (a sub-permission implies its base) set the
  orientation:

    * **base `"locations"`** opens the Locations admin pages, scoped to the
      locations the user OWNS: the list, create (owned by the creator), edit,
      delete and Structure. This is the key an operator grants so users manage
      their own sites.
    * **sub `"locations.manage_all"`** adds every location (owned or global),
      ownership assignment, internal notes, attachments and the Types pages.
      Core auto-grants every sub-permission to Admin at boot; Owner holds all
      keys.

  A scope with neither `manage_all` nor a user sees nothing.
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
  The locations the scope may see, ordered by name: every location for
  `manage_all`, otherwise only the user's own, and none without a user.

  `opts` are `Locations.list_locations/1` filters. An `owner_uuid:` among them
  is honoured only for `manage_all`; everyone else is pinned to their own uuid.
  """
  @spec list_locations(Scope.t() | nil, Locations.list_locations_opts()) :: [Location.t()]
  def list_locations(scope, opts \\ []) do
    if manage_all?(scope) do
      Locations.list_locations(opts)
    else
      case user_uuid(scope) do
        nil -> []
        uuid -> Locations.list_locations(Keyword.put(opts, :owner_uuid, uuid))
      end
    end
  end

  @doc """
  Resolves one location the scope may act on, or `nil`: any location for
  `manage_all`, otherwise only one the user owns. A malformed uuid is `nil`,
  never a raise.
  """
  @spec get_location(Scope.t() | nil, String.t() | nil) :: Location.t() | nil
  def get_location(scope, uuid) do
    if manage_all?(scope) do
      case is_binary(uuid) and Ecto.UUID.cast(uuid) do
        {:ok, _} -> Locations.get_location(uuid)
        _ -> nil
      end
    else
      Locations.get_location_for_owner(uuid, user_uuid(scope))
    end
  end

  @doc """
  The `Locations.find_similar_addresses/5` options for the scope: unrestricted
  for `manage_all`, otherwise the user's own locations only, so the
  duplicate-address warning can never name another account's location.
  """
  @spec similar_address_opts(Scope.t() | nil) :: keyword()
  def similar_address_opts(scope) do
    if manage_all?(scope), do: [], else: [owner_uuid: user_uuid(scope)]
  end
end
