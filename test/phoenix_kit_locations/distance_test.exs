defmodule PhoenixKitLocations.DistanceTest do
  use ExUnit.Case, async: true

  alias PhoenixKitLocations.Distance
  alias PhoenixKitLocations.Schemas.Location

  @tallinn {59.437, 24.7536}
  @tartu {58.378, 26.729}
  @helsinki {60.1699, 24.9384}

  test "Tallinn to Tartu is about 163 km" do
    assert_in_delta Distance.haversine(@tallinn, @tartu), 163.5, 1.0
  end

  test "is symmetric and zero for the same point" do
    assert_in_delta Distance.haversine(@tallinn, @helsinki),
                    Distance.haversine(@helsinki, @tallinn),
                    1.0e-9

    assert Distance.haversine(@tallinn, @tallinn) == 0.0
  end

  test "converts units" do
    km = Distance.haversine(@tallinn, @helsinki)
    assert_in_delta Distance.haversine(@tallinn, @helsinki, :mi), km / 1.609344, 1.0e-9
    assert_in_delta Distance.haversine(@tallinn, @helsinki, :m), km * 1000, 1.0e-6
  end

  test "antipodal points stay in asin's domain" do
    assert_in_delta Distance.haversine({0, 0}, {0, 180}), :math.pi() * 6371.0088, 1.0e-6
  end

  test "accepts Location structs, Decimals, strings and string-keyed maps" do
    loc = %Location{latitude: Decimal.new("59.437"), longitude: Decimal.new("24.7536")}
    other = %{"latitude" => "58.378", "longitude" => "26.729"}

    assert_in_delta Distance.haversine(loc, other), Distance.haversine(@tallinn, @tartu), 1.0e-9
  end

  test "a point without both coordinates has no distance" do
    assert Distance.haversine(%Location{}, @tallinn) == nil
    assert Distance.haversine(%Location{latitude: Decimal.new(1)}, @tallinn) == nil
    assert Distance.haversine({"abc", 1}, @tallinn) == nil
    assert Distance.haversine({91, 0}, @tallinn) == nil
    assert Distance.haversine(nil, @tallinn) == nil
  end

  test "a huge or non-finite coordinate has no distance instead of raising" do
    assert Distance.coordinates({Decimal.new("NaN"), 0}) == nil
    assert Distance.coordinates({Decimal.new("Infinity"), 0}) == nil
    assert Distance.coordinates({Decimal.new("1e400"), 0}) == nil
    assert Distance.coordinates({Integer.pow(10, 400), 0}) == nil
    assert Distance.haversine({0, Integer.pow(10, 400)}, {0, 0}) == nil
  end

  test "within?/4" do
    assert Distance.within?(@tallinn, @helsinki, 100)
    refute Distance.within?(@tallinn, @tartu, 100)
    refute Distance.within?(%Location{}, @tallinn, 100_000)
  end

  test "sort_by_distance/3 puts the nearest first and points without coordinates last" do
    none = %Location{name: "none"}
    sorted = Distance.sort_by_distance([@tartu, none, @helsinki], @tallinn)
    assert sorted == [@helsinki, @tartu, none]

    [{@helsinki, d} | _] =
      Distance.sort_by_distance([@tartu, @helsinki], @tallinn, with_distance: true)

    assert_in_delta d, 82.0, 2.0
  end
end
