defmodule PhoenixKitLocations.LocationOwnerTest do
  use PhoenixKitLocations.DataCase, async: true

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitLocations.Spaces

  defp location!(attrs, opts \\ []) do
    {:ok, location} =
      Locations.create_location(
        Map.merge(%{name: "Loc #{System.unique_integer([:positive])}"}, attrs),
        opts
      )

    location
  end

  defp names(locations), do: locations |> Enum.map(& &1.name) |> Enum.sort()

  describe "create_location/2 owner" do
    test "owner_uuid: in opts sets the owner" do
      owner = fixture_user()
      location = location!(%{}, owner_uuid: owner.uuid)

      assert location.owner_uuid == owner.uuid
      assert Repo.get!(Location, location.uuid).owner_uuid == owner.uuid
    end

    test "owner_uuid in attrs is ignored, with atom or string keys" do
      owner = fixture_user()

      assert location!(%{owner_uuid: owner.uuid}).owner_uuid == nil

      {:ok, from_params} =
        Locations.create_location(%{"name" => "From params", "owner_uuid" => owner.uuid})

      assert from_params.owner_uuid == nil
    end

    test "an unknown owner is a changeset error, not a raise" do
      assert {:error, changeset} =
               Locations.create_location(%{name: "Ghost"}, owner_uuid: UUIDv7.generate())

      assert errors_on(changeset).owner_uuid
    end

    test "location.created metadata carries the owner" do
      owner = fixture_user()
      location = location!(%{name: "Owned HQ"}, owner_uuid: owner.uuid, actor_uuid: owner.uuid)

      assert_activity_logged("location.created",
        resource_uuid: location.uuid,
        metadata_has: %{"name" => "Owned HQ", "owner_uuid" => owner.uuid}
      )
    end
  end

  describe "list_locations/1 and count_locations/1 owner filter" do
    setup do
      owner_a = fixture_user()
      owner_b = fixture_user()
      type = elem(Locations.create_location_type(%{name: "Warehouse"}), 1)

      a1 = location!(%{name: "A1"}, owner_uuid: owner_a.uuid)
      _a2 = location!(%{name: "A2", status: "inactive"}, owner_uuid: owner_a.uuid)
      b1 = location!(%{name: "B1"}, owner_uuid: owner_b.uuid)
      _g1 = location!(%{name: "G1"})

      {:ok, :synced} = Locations.sync_location_types(a1.uuid, [type.uuid])
      {:ok, :synced} = Locations.sync_location_types(b1.uuid, [type.uuid])

      %{owner_a: owner_a, type: type}
    end

    test "omitting the option returns every location" do
      assert names(Locations.list_locations()) == ~w(A1 A2 B1 G1)
    end

    test "an owner uuid returns only that owner's locations", %{owner_a: owner_a} do
      assert names(Locations.list_locations(owner_uuid: owner_a.uuid)) == ~w(A1 A2)
    end

    test "nil returns only unowned locations" do
      assert names(Locations.list_locations(owner_uuid: nil)) == ~w(G1)
    end

    test "a list of uuids returns locations owned by any of them", %{owner_a: owner_a} do
      owner_b_uuid =
        Locations.list_locations(owner_uuid: :any)
        |> Enum.find(&(&1.name == "B1"))
        |> Map.fetch!(:owner_uuid)

      assert names(Locations.list_locations(owner_uuid: [owner_a.uuid, owner_b_uuid])) ==
               ~w(A1 A2 B1)

      assert Locations.list_locations(owner_uuid: []) == []
      assert Locations.count_locations(owner_uuid: [owner_a.uuid]) == 2
    end

    test ":any returns every owned location" do
      assert names(Locations.list_locations(owner_uuid: :any)) == ~w(A1 A2 B1)
    end

    test "composes with status and type_uuid", %{owner_a: owner_a, type: type} do
      assert names(Locations.list_locations(owner_uuid: owner_a.uuid, status: "active")) == ~w(A1)

      assert names(Locations.list_locations(owner_uuid: owner_a.uuid, type_uuid: type.uuid)) ==
               ~w(A1)

      assert names(Locations.list_locations(owner_uuid: :any, type_uuid: type.uuid)) == ~w(A1 B1)
    end

    test "count_locations/1 applies the same filter", %{owner_a: owner_a} do
      assert Locations.count_locations() == 4
      assert Locations.count_locations(owner_uuid: owner_a.uuid) == 2
      assert Locations.count_locations(owner_uuid: owner_a.uuid, status: "active") == 1
      assert Locations.count_locations(owner_uuid: nil) == 1
      assert Locations.count_locations(owner_uuid: :any) == 3
    end
  end

  describe "get_location_for_owner/2" do
    setup do
      owner = fixture_user()
      other = fixture_user()
      %{owner: owner, other: other, mine: location!(%{name: "Mine"}, owner_uuid: owner.uuid)}
    end

    test "resolves the owner's own location with types preloaded", %{owner: owner, mine: mine} do
      found = Locations.get_location_for_owner(mine.uuid, owner.uuid)

      assert found.uuid == mine.uuid
      assert found.location_types == []
    end

    test "accepts a list of owners, any of which may match",
         %{owner: owner, other: other, mine: mine} do
      assert Locations.get_location_for_owner(mine.uuid, [other.uuid, owner.uuid]).uuid ==
               mine.uuid

      assert Locations.get_location_for_owner(mine.uuid, [other.uuid]) == nil
      assert Locations.get_location_for_owner(mine.uuid, []) == nil
      assert Locations.get_location_for_owner(mine.uuid, ["nope", nil]) == nil
    end

    test "is nil for another owner, an unowned location, or malformed input",
         %{owner: owner, other: other, mine: mine} do
      global = location!(%{name: "Global"})

      assert Locations.get_location_for_owner(mine.uuid, other.uuid) == nil
      assert Locations.get_location_for_owner(global.uuid, owner.uuid) == nil
      assert Locations.get_location_for_owner("not-a-uuid", owner.uuid) == nil
      assert Locations.get_location_for_owner(mine.uuid, "not-a-uuid") == nil
      assert Locations.get_location_for_owner(mine.uuid, nil) == nil
      assert Locations.get_location_for_owner(nil, owner.uuid) == nil
    end
  end

  describe "set_location_owner/3" do
    setup do
      %{owner_a: fixture_user(), owner_b: fixture_user(), actor: UUIDv7.generate()}
    end

    test "assigns a global location and logs owner_changed", %{owner_a: owner_a, actor: actor} do
      location = location!(%{name: "Depot"})

      assert {:ok, updated} =
               Locations.set_location_owner(location, owner_a.uuid, actor_uuid: actor)

      assert updated.owner_uuid == owner_a.uuid
      assert Repo.get!(Location, location.uuid).owner_uuid == owner_a.uuid

      assert_activity_logged("location.owner_changed",
        resource_uuid: location.uuid,
        actor_uuid: actor,
        metadata_has: %{"name" => "Depot", "owner_from" => nil, "owner_to" => owner_a.uuid}
      )
    end

    test "moves between owners and clears back to global",
         %{owner_a: owner_a, owner_b: owner_b} do
      location = location!(%{}, owner_uuid: owner_a.uuid)

      assert {:ok, moved} = Locations.set_location_owner(location, owner_b.uuid)
      assert moved.owner_uuid == owner_b.uuid

      assert {:ok, cleared} = Locations.set_location_owner(moved, nil)
      assert cleared.owner_uuid == nil
      assert Repo.get!(Location, location.uuid).owner_uuid == nil

      assert_activity_logged("location.owner_changed",
        metadata_has: %{"owner_from" => owner_a.uuid, "owner_to" => owner_b.uuid}
      )

      assert_activity_logged("location.owner_changed",
        metadata_has: %{"owner_from" => owner_b.uuid, "owner_to" => nil}
      )
    end

    test "setting the current owner again writes and logs nothing", %{owner_a: owner_a} do
      location = location!(%{}, owner_uuid: owner_a.uuid)

      assert {:ok, ^location} = Locations.set_location_owner(location, owner_a.uuid)
      assert {:ok, _} = Locations.set_location_owner(location!(%{}), nil)
      refute_activity_logged("location.owner_changed")
    end

    test "an unknown or malformed owner returns a changeset and leaves the row alone",
         %{owner_a: owner_a} do
      location = location!(%{}, owner_uuid: owner_a.uuid)

      assert {:error, unknown} = Locations.set_location_owner(location, UUIDv7.generate())
      assert errors_on(unknown).owner_uuid

      assert {:error, malformed} = Locations.set_location_owner(location, "nope")
      assert errors_on(malformed).owner_uuid

      assert Repo.get!(Location, location.uuid).owner_uuid == owner_a.uuid
    end

    test "update_location/3 never changes the owner", %{owner_a: owner_a, owner_b: owner_b} do
      location = location!(%{}, owner_uuid: owner_a.uuid)

      {:ok, updated} =
        Locations.update_location(location, %{"name" => "Renamed", "owner_uuid" => owner_b.uuid})

      assert updated.name == "Renamed"
      assert Repo.get!(Location, location.uuid).owner_uuid == owner_a.uuid
    end
  end

  describe "deleting the owner" do
    test "cascades the owner's locations and their spaces, leaving everything else" do
      owner = fixture_user()
      owned = location!(%{name: "Owned"}, owner_uuid: owner.uuid)
      global = location!(%{name: "Global"})

      {:ok, space} =
        Spaces.create_space(%{"location_uuid" => owned.uuid, "kind" => "floor", "name" => "F1"})

      {1, _} = Repo.delete_all(from(u in User, where: u.uuid == ^owner.uuid))

      assert Repo.get(Location, owned.uuid) == nil
      assert Spaces.get_space(space.uuid) == nil
      assert Repo.get(Location, global.uuid)
    end

    test "before_user_delete/1 logs location.deleted for each owned location" do
      owner = fixture_user()
      other = fixture_user()
      owned = location!(%{name: "Owned"}, owner_uuid: owner.uuid)
      theirs = location!(%{name: "Theirs"}, owner_uuid: other.uuid)

      assert PhoenixKitLocations.before_user_delete(owner.uuid) == :ok

      row =
        assert_activity_logged("location.deleted",
          resource_uuid: owned.uuid,
          metadata_has: %{"reason" => "owner_deleted", "owner_uuid" => owner.uuid}
        )

      assert row.mode == "auto"
      refute_activity_logged("location.deleted", resource_uuid: theirs.uuid)
    end

    test "log_owner_deletion/1 tolerates garbage input" do
      assert Locations.log_owner_deletion("not-a-uuid") == :ok
      assert Locations.log_owner_deletion(nil) == :ok
    end
  end

  describe "find_similar_addresses/5 owner scope" do
    test "an owner scope only matches that owner's locations" do
      owner = fixture_user()
      other = fixture_user()
      address = %{address_line_1: "1 Dock Road", city: "Tallinn", postal_code: "10111"}

      location!(Map.put(address, :name, "Mine"), owner_uuid: owner.uuid)
      location!(Map.put(address, :name, "Theirs"), owner_uuid: other.uuid)

      assert ["Mine"] ==
               "1 Dock Road"
               |> Locations.find_similar_addresses("Tallinn", "10111", nil,
                 owner_uuid: owner.uuid
               )
               |> Enum.map(& &1.name)

      assert ~w(Mine Theirs) ==
               "1 Dock Road"
               |> Locations.find_similar_addresses("Tallinn", "10111")
               |> Enum.map(& &1.name)
               |> Enum.sort()
    end
  end
end
