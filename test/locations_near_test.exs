defmodule PhoenixKitLocations.LocationsNearTest do
  use PhoenixKitLocations.DataCase, async: true

  alias PhoenixKitLocations.Distance
  alias PhoenixKitLocations.Locations

  defp loc(name, lat, lng) do
    attrs = if lat, do: %{latitude: lat, longitude: lng}, else: %{}
    {:ok, l} = Locations.create_location(Map.put(attrs, :name, name))
    l
  end

  test "near: keeps locations within the radius, nearest first, matching Distance" do
    helsinki = loc("Helsinki", "60.1699", "24.9384")
    tartu = loc("Tartu", "58.378", "26.729")
    _riga = loc("Riga", "56.9496", "24.1052")
    _none = loc("Nowhere", nil, nil)

    origin = {59.437, 24.7536}

    assert [h, t] = Locations.list_locations(near: {59.437, 24.7536, 200})
    assert h.uuid == helsinki.uuid
    assert t.uuid == tartu.uuid
    assert Distance.haversine(origin, t) < 200

    assert [%{name: "Helsinki"}] =
             Locations.list_locations(near: {Decimal.new("59.437"), 24.7536, 100})

    assert [] = Locations.list_locations(near: {59.437, 24.7536, 1})
  end

  test "near: crosses the antimeridian" do
    east = loc("East", "0", "179.9")
    _far = loc("Far", "0", "0")

    assert [found] = Locations.list_locations(near: {0, -179.9, 50})
    assert found.uuid == east.uuid
  end

  test "near: composes with other filters" do
    _ = loc("Helsinki", "60.1699", "24.9384")

    assert [] =
             Locations.list_locations(
               near: {59.437, 24.7536, 200},
               owner_uuid: nil,
               status: "inactive"
             )
  end

  test "near: rejects a malformed value" do
    assert_raise ArgumentError, fn -> Locations.list_locations(near: {1, 2}) end
    assert_raise ArgumentError, fn -> Locations.list_locations(near: {"a", 2, 3}) end
  end

  test "the database CHECK holds coordinates in range even past the changeset" do
    l = loc("X", nil, nil)

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "UPDATE phoenix_kit_locations SET latitude = 95, longitude = 0 WHERE uuid = $1",
        [
          Ecto.UUID.dump!(l.uuid)
        ]
      )
    end
  end
end
