defmodule PhoenixKitLocations.LocationsTest do
  use PhoenixKitLocations.DataCase, async: true

  alias PhoenixKitLocations.Locations

  # ── Helpers ──────────────────────────────────────────────────────

  defp create_location_type(attrs \\ %{}) do
    {:ok, t} = Locations.create_location_type(Map.merge(%{name: "Test Type"}, attrs))
    t
  end

  defp create_location(attrs \\ %{}) do
    {:ok, l} = Locations.create_location(Map.merge(%{name: "Test Location"}, attrs))
    l
  end

  # ═══════════════════════════════════════════════════════════════════
  # Location Types
  # ═══════════════════════════════════════════════════════════════════

  describe "location types" do
    test "create_location_type/1 with valid attrs" do
      assert {:ok, t} = Locations.create_location_type(%{name: "Showroom"})
      assert t.name == "Showroom"
      assert t.status == "active"
    end

    test "create_location_type/1 requires name" do
      assert {:error, changeset} = Locations.create_location_type(%{})
      assert errors_on(changeset).name
    end

    test "list_location_types/0 returns all ordered by name" do
      create_location_type(%{name: "Zebra"})
      create_location_type(%{name: "Alpha"})
      types = Locations.list_location_types()
      assert length(types) == 2
      assert hd(types).name == "Alpha"
    end

    test "list_location_types/1 filters by status" do
      create_location_type(%{name: "Active", status: "active"})
      create_location_type(%{name: "Inactive", status: "inactive"})
      assert length(Locations.list_location_types(status: "active")) == 1
      assert length(Locations.list_location_types(status: "inactive")) == 1
    end

    test "get_location_type/1 returns type or nil" do
      t = create_location_type()
      assert Locations.get_location_type(t.uuid).uuid == t.uuid
      assert is_nil(Locations.get_location_type(Ecto.UUID.generate()))
    end

    test "update_location_type/2" do
      t = create_location_type()
      assert {:ok, updated} = Locations.update_location_type(t, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "delete_location_type/1" do
      t = create_location_type()
      assert {:ok, _} = Locations.delete_location_type(t)
      assert is_nil(Locations.get_location_type(t.uuid))
    end

    test "change_location_type/2 returns changeset" do
      t = create_location_type()
      changeset = Locations.change_location_type(t, %{name: "Changed"})
      assert %Ecto.Changeset{} = changeset
    end

    test "get_location_type_by_name/1" do
      create_location_type(%{name: "Showroom"})
      assert Locations.get_location_type_by_name("Showroom").name == "Showroom"
      assert is_nil(Locations.get_location_type_by_name("Nonexistent"))
    end

    test "count_location_types/0" do
      create_location_type(%{name: "A"})
      create_location_type(%{name: "B", status: "inactive"})
      assert Locations.count_location_types() == 2
      assert Locations.count_location_types(status: "active") == 1
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Locations
  # ═══════════════════════════════════════════════════════════════════

  describe "locations" do
    test "create_location/1 with valid attrs" do
      assert {:ok, l} = Locations.create_location(%{name: "Main Office"})
      assert l.name == "Main Office"
      assert l.status == "active"
    end

    test "create_location/1 with full attrs" do
      assert {:ok, l} =
               Locations.create_location(%{
                 name: "HQ",
                 description: "Headquarters",
                 public_notes: "Ring bell twice",
                 address_line_1: "123 Main St",
                 address_line_2: "Suite 100",
                 city: "Springfield",
                 state: "IL",
                 postal_code: "62701",
                 country: "US",
                 phone: "+1 555 0100",
                 email: "hq@example.com",
                 website: "https://example.com",
                 notes: "Internal note",
                 features: %{"elevator" => true, "parking" => true}
               })

      assert l.address_line_1 == "123 Main St"
      assert l.features["elevator"] == true
    end

    test "create_location/1 requires name" do
      assert {:error, changeset} = Locations.create_location(%{})
      assert errors_on(changeset).name
    end

    test "create_location/1 validates email format" do
      assert {:error, changeset} = Locations.create_location(%{name: "Test", email: "bad"})
      assert errors_on(changeset).email
    end

    test "create_location/1 validates website format" do
      assert {:error, changeset} = Locations.create_location(%{name: "Test", website: "bad"})
      assert errors_on(changeset).website
    end

    test "list_locations/0 returns all with types preloaded" do
      create_location(%{name: "A"})
      create_location(%{name: "B"})
      locations = Locations.list_locations()
      assert length(locations) == 2
      # Types should be preloaded (empty list, not unloaded)
      assert hd(locations).location_types == []
    end

    test "list_locations/1 filters by status" do
      create_location(%{name: "Active", status: "active"})
      create_location(%{name: "Inactive", status: "inactive"})
      assert length(Locations.list_locations(status: "active")) == 1
    end

    test "list_locations/1 filters by type_uuid" do
      l1 = create_location(%{name: "A"})
      _l2 = create_location(%{name: "B"})
      t = create_location_type(%{name: "Showroom"})
      {:ok, _} = Locations.sync_location_types(l1.uuid, [t.uuid])

      results = Locations.list_locations(type_uuid: t.uuid)
      assert length(results) == 1
      assert hd(results).name == "A"
    end

    test "get_location_by/2" do
      create_location(%{name: "HQ", email: "hq@test.com"})
      assert Locations.get_location_by(:name, "HQ").name == "HQ"
      assert Locations.get_location_by(:email, "hq@test.com").email == "hq@test.com"
      assert is_nil(Locations.get_location_by(:name, "Nonexistent"))
    end

    test "count_locations/0" do
      create_location(%{name: "A"})
      create_location(%{name: "B", status: "inactive"})
      assert Locations.count_locations() == 2
      assert Locations.count_locations(status: "active") == 1
    end

    test "get_location/1 returns location with types or nil" do
      l = create_location()
      found = Locations.get_location(l.uuid)
      assert found.uuid == l.uuid
      assert found.location_types == []
      assert is_nil(Locations.get_location(Ecto.UUID.generate()))
    end

    test "update_location/2" do
      l = create_location()
      assert {:ok, updated} = Locations.update_location(l, %{name: "Updated"})
      assert updated.name == "Updated"
    end

    test "delete_location/1" do
      l = create_location()
      assert {:ok, _} = Locations.delete_location(l)
      assert is_nil(Locations.get_location(l.uuid))
    end

    test "change_location/2 returns changeset" do
      l = create_location()
      changeset = Locations.change_location(l, %{name: "Changed"})
      assert %Ecto.Changeset{} = changeset
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Location ↔ Type linking
  # ═══════════════════════════════════════════════════════════════════

  describe "location type linking" do
    test "sync_location_types/2 assigns types" do
      l = create_location()
      t1 = create_location_type(%{name: "Showroom"})
      t2 = create_location_type(%{name: "Storage"})

      assert {:ok, _} = Locations.sync_location_types(l.uuid, [t1.uuid, t2.uuid])
      assert MapSet.new(Locations.linked_type_uuids(l.uuid)) == MapSet.new([t1.uuid, t2.uuid])
    end

    test "sync_location_types/2 replaces existing assignments" do
      l = create_location()
      t1 = create_location_type(%{name: "Showroom"})
      t2 = create_location_type(%{name: "Storage"})
      t3 = create_location_type(%{name: "Office"})

      {:ok, _} = Locations.sync_location_types(l.uuid, [t1.uuid, t2.uuid])
      {:ok, _} = Locations.sync_location_types(l.uuid, [t3.uuid])

      assert Locations.linked_type_uuids(l.uuid) == [t3.uuid]
    end

    test "sync_location_types/2 with empty list removes all" do
      l = create_location()
      t1 = create_location_type(%{name: "Showroom"})
      {:ok, _} = Locations.sync_location_types(l.uuid, [t1.uuid])

      {:ok, _} = Locations.sync_location_types(l.uuid, [])
      assert Locations.linked_type_uuids(l.uuid) == []
    end

    test "linked_type_uuids/1 returns empty list for new location" do
      l = create_location()
      assert Locations.linked_type_uuids(l.uuid) == []
    end

    test "types are preloaded via get_location/1" do
      l = create_location()
      t = create_location_type(%{name: "Showroom"})
      {:ok, _} = Locations.sync_location_types(l.uuid, [t.uuid])

      found = Locations.get_location(l.uuid)
      assert length(found.location_types) == 1
      assert hd(found.location_types).name == "Showroom"
    end

    test "types are preloaded via list_locations/0" do
      l = create_location()
      t = create_location_type(%{name: "Showroom"})
      {:ok, _} = Locations.sync_location_types(l.uuid, [t.uuid])

      [found] = Locations.list_locations()
      assert length(found.location_types) == 1
    end

    test "deleting a type cascades to assignments" do
      l = create_location()
      t = create_location_type(%{name: "Showroom"})
      {:ok, _} = Locations.sync_location_types(l.uuid, [t.uuid])

      {:ok, _} = Locations.delete_location_type(t)
      assert Locations.linked_type_uuids(l.uuid) == []
    end

    test "deleting a location cascades to assignments" do
      l = create_location()
      t = create_location_type(%{name: "Showroom"})
      {:ok, _} = Locations.sync_location_types(l.uuid, [t.uuid])

      {:ok, _} = Locations.delete_location(l)
      # Type still exists, just no assignments
      assert Locations.get_location_type(t.uuid) != nil
    end

    test "linked_types/1 returns type structs" do
      l = create_location()
      t1 = create_location_type(%{name: "Showroom"})
      t2 = create_location_type(%{name: "Storage"})
      {:ok, _} = Locations.sync_location_types(l.uuid, [t1.uuid, t2.uuid])

      types = Locations.linked_types(l.uuid)
      assert length(types) == 2
      names = Enum.map(types, & &1.name)
      assert "Showroom" in names
      assert "Storage" in names
    end

    test "add_location_type/2 adds a single type" do
      l = create_location()
      t = create_location_type(%{name: "Showroom"})

      assert {:ok, _} = Locations.add_location_type(l.uuid, t.uuid)
      assert Locations.linked_type_uuids(l.uuid) == [t.uuid]
    end

    test "add_location_type/2 is idempotent" do
      l = create_location()
      t = create_location_type(%{name: "Showroom"})

      {:ok, _} = Locations.add_location_type(l.uuid, t.uuid)
      {:ok, _} = Locations.add_location_type(l.uuid, t.uuid)
      assert length(Locations.linked_type_uuids(l.uuid)) == 1
    end

    test "remove_location_type/2 removes a single type" do
      l = create_location()
      t1 = create_location_type(%{name: "Showroom"})
      t2 = create_location_type(%{name: "Storage"})
      {:ok, _} = Locations.sync_location_types(l.uuid, [t1.uuid, t2.uuid])

      {:ok, 1} = Locations.remove_location_type(l.uuid, t1.uuid)
      assert Locations.linked_type_uuids(l.uuid) == [t2.uuid]
    end

    test "remove_location_type/2 is no-op if not assigned" do
      l = create_location()
      t = create_location_type(%{name: "Showroom"})

      {:ok, 0} = Locations.remove_location_type(l.uuid, t.uuid)
    end

    test "has_type?/2" do
      l = create_location()
      t = create_location_type(%{name: "Showroom"})

      refute Locations.has_type?(l.uuid, t.uuid)
      {:ok, _} = Locations.add_location_type(l.uuid, t.uuid)
      assert Locations.has_type?(l.uuid, t.uuid)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Duplicate address detection
  # ═══════════════════════════════════════════════════════════════════

  describe "find_similar_addresses/4" do
    test "finds matching addresses (case insensitive)" do
      create_location(%{
        name: "Office A",
        address_line_1: "123 Main St",
        city: "Springfield",
        postal_code: "62701"
      })

      results = Locations.find_similar_addresses("123 main st", "springfield", "62701")
      assert length(results) == 1
      assert hd(results).name == "Office A"
    end

    test "returns empty when no match" do
      create_location(%{
        name: "Office A",
        address_line_1: "123 Main St",
        city: "Springfield",
        postal_code: "62701"
      })

      assert Locations.find_similar_addresses("456 Oak Ave", "Springfield", "62701") == []
    end

    test "excludes given uuid" do
      l =
        create_location(%{
          name: "Office A",
          address_line_1: "123 Main St",
          city: "Springfield",
          postal_code: "62701"
        })

      assert Locations.find_similar_addresses("123 Main St", "Springfield", "62701", l.uuid) == []
    end

    test "returns empty for blank address" do
      create_location(%{name: "Office A", address_line_1: "123 Main St"})

      assert Locations.find_similar_addresses("", "", "") == []
      assert Locations.find_similar_addresses(nil, nil, nil) == []
    end

    test "matches with whitespace differences" do
      create_location(%{name: "Office A", address_line_1: "  123 Main St  ", city: "Springfield"})

      results = Locations.find_similar_addresses("123 Main St", "Springfield", "")
      assert length(results) == 1
    end

    test "handles unicode input" do
      create_location(%{name: "Café", address_line_1: "Rue de l'Étoile", city: "Paris"})

      results = Locations.find_similar_addresses("Rue de l'Étoile", "Paris", "")
      assert length(results) == 1
    end

    # The "table missing" rescue test lives in
    # `test/destructive_rescue_test.exs` (async: false) — running it
    # alongside async tests deadlocks on the DROP TABLE.
  end

  # ═══════════════════════════════════════════════════════════════════
  # Validation edge cases
  # ═══════════════════════════════════════════════════════════════════

  alias PhoenixKitLocations.Schemas.Location, as: LocationSchema

  describe "changeset validations" do
    test "rejects unknown status values" do
      {:error, cs} = Locations.create_location(%{name: "X", status: "bogus"})
      assert errors_on(cs).status
    end

    test "enforces name length limit" do
      {:error, cs} = Locations.create_location(%{name: String.duplicate("a", 300)})
      assert errors_on(cs).name
    end

    test "enforces description length limit" do
      {:error, cs} =
        Locations.create_location(%{
          name: "HQ",
          description: String.duplicate("d", 2100)
        })

      assert errors_on(cs).description
    end

    test "empty email is accepted (optional field)" do
      assert {:ok, _} = Locations.create_location(%{name: "HQ", email: ""})
    end

    test "empty website is accepted (optional field)" do
      assert {:ok, _} = Locations.create_location(%{name: "HQ", website: ""})
    end

    test "preserves Unicode round-trip in name + city + notes" do
      attrs = %{
        name: "東京本部 — Tōkyō HQ 🗼",
        city: "東京",
        country: "日本",
        public_notes: "ベルが壊れています — please knock loudly. Звонок не работает."
      }

      assert {:ok, loc} = Locations.create_location(attrs)
      reloaded = Locations.get_location(loc.uuid)

      assert reloaded.name == attrs.name
      assert reloaded.city == attrs.city
      assert reloaded.country == attrs.country
      assert reloaded.public_notes == attrs.public_notes
    end

    test "accepts SQL-metacharacter strings without crashing or escaping" do
      # Single quotes, semicolons, comment markers — Ecto's parameterised
      # queries treat these as data, not SQL syntax. Round-trip should
      # preserve byte-for-byte.
      payloads = [
        "Robert'); DROP TABLE phoenix_kit_locations; --",
        "Bob \" OR 1=1 --",
        "<script>alert('x')</script>",
        "\\u0000 NUL",
        "newline\nin\tname"
      ]

      for payload <- payloads do
        assert {:ok, loc} = Locations.create_location(%{name: payload})
        assert Locations.get_location(loc.uuid).name == payload
      end

      assert Locations.count_locations() >= length(payloads)
    end

    test "name >255 chars rejected with explicit length error" do
      {:error, cs} = Locations.create_location(%{name: String.duplicate("a", 256)})

      assert {:name, {_, [count: 255, validation: :length, kind: :max, type: :string]}} =
               Enum.find(cs.errors, fn {field, _} -> field == :name end)
    end

    test "phone >50 chars rejected" do
      {:error, cs} =
        Locations.create_location(%{name: "X", phone: String.duplicate("9", 51)})

      assert errors_on(cs).phone
    end

    test "very long postal_code rejected (>20)" do
      {:error, cs} =
        Locations.create_location(%{name: "X", postal_code: String.duplicate("0", 21)})

      assert errors_on(cs).postal_code
    end

    test "changeset on a struct with empty-string :email skips format validation" do
      # `cast/3` strips "" → nil for new params, so the only way to
      # exercise the `"" -> changeset` branch in `maybe_validate_email`
      # is to start with a struct whose `:email` field is already an
      # empty string and let `get_field/2` fall back to the data.
      changeset =
        LocationSchema.changeset(
          %LocationSchema{email: ""},
          %{name: "X"}
        )

      assert changeset.valid?
      refute changeset.errors[:email]
    end

    test "changeset on a struct with empty-string :website skips format validation" do
      changeset =
        LocationSchema.changeset(
          %LocationSchema{website: ""},
          %{name: "X"}
        )

      assert changeset.valid?
      refute changeset.errors[:website]
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Public API surface
  # ═══════════════════════════════════════════════════════════════════

  describe "get_location_by/2 allowlist" do
    test "rejects fields outside the allowlist" do
      create_location(%{name: "HQ"})

      assert_raise FunctionClauseError, fn ->
        Locations.get_location_by(:notes, "anything")
      end
    end
  end

  describe "sync_location_types/3 semantics" do
    test "returns :unchanged when types didn't change" do
      l = create_location()
      t = create_location_type()

      {:ok, :synced} = Locations.sync_location_types(l.uuid, [t.uuid])
      assert {:ok, :unchanged} = Locations.sync_location_types(l.uuid, [t.uuid])
    end

    test "returns :synced when the set actually changes" do
      l = create_location()
      t1 = create_location_type(%{name: "A"})
      t2 = create_location_type(%{name: "B"})

      assert {:ok, :synced} = Locations.sync_location_types(l.uuid, [t1.uuid])
      assert {:ok, :synced} = Locations.sync_location_types(l.uuid, [t1.uuid, t2.uuid])
    end

    test "sync with nonexistent type_uuid rolls back and preserves existing assignments" do
      l = create_location()
      t = create_location_type(%{name: "Real"})

      # Establish a baseline assignment.
      {:ok, :synced} = Locations.sync_location_types(l.uuid, [t.uuid])
      assert Locations.linked_type_uuids(l.uuid) == [t.uuid]

      bogus = Ecto.UUID.generate()

      # The FK constraint surfaces as a clean `{:error,
      # :type_assignment_failed}` (LocationTypeAssignment.changeset/2
      # wires `assoc_constraint/2` for both FK fields, so an unknown
      # type_uuid comes back as a changeset error, the transaction
      # rolls back via `repo.rollback(:type_assignment_failed)`, and
      # the wrapper returns the rollback reason).
      assert {:error, :type_assignment_failed} =
               Locations.sync_location_types(l.uuid, [t.uuid, bogus])

      # Rollback verified: the original single assignment survives.
      assert Locations.linked_type_uuids(l.uuid) == [t.uuid]
    end

    test "sync with empty list clears all assignments" do
      l = create_location()
      t1 = create_location_type(%{name: "A"})
      t2 = create_location_type(%{name: "B"})

      {:ok, :synced} = Locations.sync_location_types(l.uuid, [t1.uuid, t2.uuid])
      assert length(Locations.linked_type_uuids(l.uuid)) == 2

      assert {:ok, :synced} = Locations.sync_location_types(l.uuid, [])
      assert Locations.linked_type_uuids(l.uuid) == []
    end
  end

  describe "find_similar_addresses — safety" do
    test "handles SQL metacharacters in input without crashing" do
      # Parametrised queries mean these are harmless, but the function
      # should still just return [] (no match).
      create_location(%{name: "X", address_line_1: "123 Main St", city: "SF"})

      assert [] = Locations.find_similar_addresses("'; DROP TABLE x; --", "SF", "")
      assert [] = Locations.find_similar_addresses("%%%", "SF", "")
      assert [] = Locations.find_similar_addresses("_", "SF", "")
    end

    test "limits to 5 results" do
      # Create 6 locations sharing the same address so the limit fires.
      for i <- 1..6 do
        create_location(%{
          name: "L#{i}",
          address_line_1: "100 Same St",
          city: "Limit City",
          postal_code: "111"
        })
      end

      results = Locations.find_similar_addresses("100 Same St", "Limit City", "111")
      assert length(results) == 5
    end
  end
end
