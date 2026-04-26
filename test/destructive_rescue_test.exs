defmodule PhoenixKitLocations.DestructiveRescueTest do
  @moduledoc """
  Coverage for rescue/recovery branches that require a destructive
  DROP TABLE inside the test transaction.

  These tests share schema-level resources with the rest of the suite,
  so they MUST run `async: false` to avoid deadlock against parallel
  async tests holding row locks on the same tables. Sandbox rolls back
  the DROP at test exit, leaving the schema intact for subsequent
  test files.

  Each test exercises a `rescue Postgrex.Error -> ...` clause that
  would otherwise be unreachable without an in-process DB-error
  injection (which we don't have, since we deliberately don't pull in
  Mox).
  """

  use PhoenixKitLocations.LiveCase, async: false

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Test.Repo, as: TestRepo

  @actor Ecto.UUID.generate()

  describe "Locations context rescues" do
    test "find_similar_addresses returns [] when the locations table is missing" do
      Locations.find_similar_addresses("baseline", "City", "00000")

      TestRepo.query!("DROP TABLE phoenix_kit_location_type_assignments CASCADE")

      TestRepo.query!("DROP TABLE phoenix_kit_locations CASCADE")

      assert [] = Locations.find_similar_addresses("123 Main", "Some City", "00000")
    end

    test "create_location still succeeds when phoenix_kit_activities is missing" do
      TestRepo.query!("DROP TABLE phoenix_kit_activities")

      assert {:ok, location} =
               Locations.create_location(%{name: "NoActivityTable"}, actor_uuid: @actor)

      assert location.uuid
    end
  end

  describe "LocationsLive load_data rescues" do
    test "index tab flashes a load-failure message when the table is missing", %{conn: conn} do
      TestRepo.query!("DROP TABLE phoenix_kit_location_type_assignments CASCADE")

      TestRepo.query!("DROP TABLE phoenix_kit_locations CASCADE")

      {:ok, _view, html} = live(conn, "/en/admin/locations/")

      assert html =~ "Failed to load locations."
    end

    test "types tab flashes a load-failure message when the table is missing", %{conn: conn} do
      TestRepo.query!("DROP TABLE phoenix_kit_location_type_assignments CASCADE")

      TestRepo.query!("DROP TABLE phoenix_kit_location_types CASCADE")

      {:ok, _view, html} = live(conn, "/en/admin/locations/types")

      assert html =~ "Failed to load location types."
    end
  end
end
