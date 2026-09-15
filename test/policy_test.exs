defmodule PhoenixKitLocations.PolicyTest do
  # LiveCase for its sandbox, `enable_locations/0` and `fake_scope/1`.
  use PhoenixKitLocations.LiveCase

  alias PhoenixKit.Users.Permissions
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Policy

  defp owned(owner, name) do
    {:ok, location} = Locations.create_location(%{name: name}, owner_uuid: owner.uuid)
    location
  end

  defp base_scope(user), do: fake_scope(user_uuid: user.uuid, permissions: ["locations"])

  describe "manage_all?/1" do
    test "needs the locations.manage_all sub-permission" do
      assert Policy.manage_all?(fake_scope())
      refute Policy.manage_all?(fake_scope(permissions: ["locations"]))
      refute Policy.manage_all?(nil)
    end

    test "is inert while the module is disabled" do
      PhoenixKit.Settings.update_boolean_setting("locations_enabled", false)
      refute Policy.manage_all?(fake_scope())
    end

    test "core registers the sub-permission from permission_metadata/0" do
      assert Policy.manage_all_key() in Permissions.sub_permission_keys()
      assert Permissions.parent_key(Policy.manage_all_key()) == "locations"
    end
  end

  describe "list_locations/2" do
    setup do
      user = fixture_user()
      other = fixture_user()

      owned(user, "Mine")
      owned(other, "Theirs")
      fixture_location(%{name: "Global"})

      %{user: user, other: other}
    end

    defp names(locations), do: locations |> Enum.map(& &1.name) |> Enum.sort()

    test "manage_all sees every location and may filter by owner", %{other: other} do
      assert names(Policy.list_locations(fake_scope())) == ~w(Global Mine Theirs)
      assert names(Policy.list_locations(fake_scope(), owner_uuid: nil)) == ~w(Global)
      assert names(Policy.list_locations(fake_scope(), owner_uuid: other.uuid)) == ~w(Theirs)
    end

    test "the base permission is pinned to the user's own, whatever the opts say",
         %{user: user, other: other} do
      assert names(Policy.list_locations(base_scope(user))) == ~w(Mine)
      assert names(Policy.list_locations(base_scope(user), owner_uuid: other.uuid)) == ~w(Mine)
      assert names(Policy.list_locations(base_scope(user), owner_uuid: nil)) == ~w(Mine)
    end

    test "a scope with neither manage_all nor a user sees nothing" do
      assert Policy.list_locations(nil) == []
      assert Policy.list_locations(fake_scope(user_uuid: nil, permissions: ["locations"])) == []
    end
  end

  describe "get_location/2" do
    test "manage_all resolves any location; the base permission only its own" do
      user = fixture_user()
      other = fixture_user()
      mine = owned(user, "Mine")
      theirs = owned(other, "Theirs")

      assert Policy.get_location(fake_scope(), theirs.uuid).uuid == theirs.uuid
      assert Policy.get_location(base_scope(user), mine.uuid).uuid == mine.uuid
      assert Policy.get_location(base_scope(user), theirs.uuid) == nil
    end

    test "malformed input is nil, never a raise" do
      user = fixture_user()

      for scope <- [fake_scope(), base_scope(user), nil], uuid <- ["nope", nil] do
        assert Policy.get_location(scope, uuid) == nil
      end
    end
  end

  test "similar_address_opts/1 scopes the duplicate warning to the user's own" do
    user = fixture_user()

    assert Policy.similar_address_opts(fake_scope()) == []
    assert Policy.similar_address_opts(base_scope(user)) == [owner_uuid: user.uuid]
  end
end
