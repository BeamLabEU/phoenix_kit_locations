defmodule PhoenixKitLocations.Schemas.LocationCoordinatesTest do
  use ExUnit.Case, async: true

  alias PhoenixKitLocations.Schemas.Location

  defp changeset(attrs), do: Location.changeset(%Location{}, Map.put(attrs, "name", "X"))

  test "coordinates are optional" do
    assert changeset(%{}).valid?
    assert changeset(%{"latitude" => "", "longitude" => ""}).valid?
  end

  test "casts strings to Decimals rounded to the column's 6 places" do
    cs = changeset(%{"latitude" => "59.43700049", "longitude" => "24.7536"})
    assert cs.valid?
    assert Decimal.equal?(Ecto.Changeset.get_change(cs, :latitude), Decimal.new("59.437000"))
  end

  test "rejects out-of-range values" do
    cs = changeset(%{"latitude" => "90.1", "longitude" => "-180.5"})
    refute cs.valid?
    assert {"must be between -90 and 90", _} = cs.errors[:latitude]
    assert {"must be between -180 and 180", _} = cs.errors[:longitude]
  end

  test "a huge or non-finite value is an error, not a raise" do
    for value <- ["1e28", "1e400"] do
      cs = changeset(%{"latitude" => value, "longitude" => "0"})
      refute cs.valid?
      assert cs.errors[:latitude]
    end
  end

  test "a value a hair past ±180 rounds to the edge instead of failing" do
    cs = changeset(%{"latitude" => "0", "longitude" => "180.0000004"})
    assert cs.valid?
    assert Decimal.equal?(Ecto.Changeset.get_change(cs, :longitude), Decimal.new(180))
  end

  test "requires both or neither" do
    cs = changeset(%{"latitude" => "59.4"})
    refute cs.valid?
    assert {"enter both latitude and longitude", _} = cs.errors[:longitude]

    cs = changeset(%{"longitude" => "24.7"})
    assert {"enter both latitude and longitude", _} = cs.errors[:latitude]
  end

  test "clearing one coordinate of a stored pair is refused" do
    stored = %Location{name: "X", latitude: Decimal.new("1"), longitude: Decimal.new("2")}
    cs = Location.changeset(stored, %{"latitude" => ""})
    refute cs.valid?
    assert cs.errors[:latitude]
  end

  test "coordinates_changeset/2 casts only coordinates" do
    cs =
      Location.coordinates_changeset(%Location{name: "X"}, %{latitude: 1, longitude: 2, name: "Y"})

    assert cs.valid?
    refute Map.has_key?(cs.changes, :name)
  end
end
