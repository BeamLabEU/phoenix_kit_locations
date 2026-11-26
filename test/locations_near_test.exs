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

  # The prefilter box must contain the whole circle. Each point below is
  # inside the radius (Distance agrees) but was outside the old box.
  test "near: a circle that reaches a pole keeps points across it" do
    across = loc("Across the pole", "88", "180")
    assert Distance.haversine({85, 0}, across) < 1000

    assert [found] = Locations.list_locations(near: {85, 0, 1000})
    assert found.uuid == across.uuid
  end

  test "near: at high latitude the box is as wide as the circle's widest point" do
    # Poleward of the centre the circle spans more longitude than r / cos(φ0).
    edge = loc("Edge", "61.26", "18.168")
    assert Distance.haversine({60, 0}, edge) < 1000

    assert [found] = Locations.list_locations(near: {60, 0, 1000})
    assert found.uuid == edge.uuid
  end

  test "near: the box contains the circle for random centres and radii" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..2000 do
      lat = :rand.uniform() * 180 - 90
      radius = :rand.uniform() * 5000
      {dlat, dlng} = Locations.bounding_box(lat, radius)
      # The point of the circle farthest east (a great circle from the
      # centre at the bearing that maximises Δλ) and farthest north/south.
      d = radius / Distance.earth_radius_km()
      phi = lat * :math.pi() / 180
      ratio = :math.sin(d) / :math.cos(phi)

      if dlng < 180.0 do
        assert ratio < 1.0
        max_dlng = :math.asin(ratio) * 180 / :math.pi()
        assert dlng >= max_dlng, "lat #{lat} r #{radius}: #{dlng} < #{max_dlng}"
      end

      assert dlat >= d * 180 / :math.pi()
    end
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
