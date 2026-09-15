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

  test "similar_address_opts/1 scopes the duplicate warning to the user's owners" do
    user = fixture_user()

    assert Policy.similar_address_opts(fake_scope()) == []
    assert Policy.similar_address_opts(base_scope(user)) == [owner_uuid: [user.uuid]]
  end

  describe "organizations" do
    setup do
      org = fixture_user(%{account_type: "organization", organization_name: "Trinity Wood"})
      member = fixture_user(%{organization_uuid: org.uuid})
      teammate = fixture_user(%{organization_uuid: org.uuid})
      rival_org = fixture_user(%{account_type: "organization", organization_name: "Rival"})

      %{org: org, member: member, teammate: teammate, rival_org: rival_org}
    end

    defp member_scope(user),
      do:
        fake_scope(
          user_uuid: user.uuid,
          organization_uuid: user.organization_uuid,
          permissions: ["locations"]
        )

    test "owner_uuids/1 is the user plus their organization", %{org: org, member: member} do
      assert Policy.owner_uuids(member_scope(member)) == [member.uuid, org.uuid]
      assert Policy.owner_uuids(member) == [member.uuid, org.uuid]
      assert Policy.owner_uuids(org) == [org.uuid]
      assert Policy.owner_uuids(nil) == []
    end

    test "new_owner_uuid/1 is the organization when there is one", %{org: org, member: member} do
      solo = fixture_user()

      assert Policy.new_owner_uuid(member_scope(member)) == org.uuid
      assert Policy.new_owner_uuid(base_scope(solo)) == solo.uuid
      assert Policy.new_owner_uuid(nil) == nil
    end

    test "a member sees their own and their organization's locations, not a teammate's personal ones",
         %{org: org, member: member, teammate: teammate, rival_org: rival_org} do
      owned(org, "Company Warehouse")
      owned(member, "Member Personal")
      owned(teammate, "Teammate Personal")
      owned(rival_org, "Rival Warehouse")

      assert names(Policy.list_locations(member_scope(member))) ==
               ["Company Warehouse", "Member Personal"]

      assert names(Policy.list_locations(member_scope(teammate))) ==
               ["Company Warehouse", "Teammate Personal"]
    end

    test "get_location/2 resolves the organization's location for every member",
         %{org: org, member: member, teammate: teammate, rival_org: rival_org} do
      company = owned(org, "Company Warehouse")
      rival = owned(rival_org, "Rival Warehouse")

      assert Policy.get_location(member_scope(member), company.uuid).uuid == company.uuid
      assert Policy.get_location(member_scope(teammate), company.uuid).uuid == company.uuid
      assert Policy.get_location(member_scope(member), rival.uuid) == nil
    end
  end
end
