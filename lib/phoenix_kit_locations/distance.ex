defmodule PhoenixKitLocations.Distance do
  @moduledoc """
  Great-circle (haversine) distance between two points on a sphere of the
  mean Earth radius (6371.0088 km). Accurate to about 0.5 % against the
  ellipsoid, which is plenty for "nearest shop" lists and radius filters.

  A point is a `%Location{}` (or any map with `:latitude` / `:longitude`),
  a `{latitude, longitude}` tuple, or a `%{"latitude" => …}` map; each
  coordinate is a number, a `Decimal` or a numeric string, in decimal
  degrees. A point without both coordinates gives `nil`, never a raise, so
  locations that were never geocoded simply have no distance.

      Distance.haversine(location_a, location_b)          #=> 12.34 (km)
      Distance.haversine({59.437, 24.7536}, loc, :mi)     #=> 7.67
      Distance.sort_by_distance(locations, {59.437, 24.7536})

  The SQL side of the same formula is `Locations.list_locations(near: ...)`.
  """

  @earth_radius_km 6371.0088
  @km_per_mile 1.609344

  @type unit :: :km | :mi | :m
  @type point ::
          {number() | Decimal.t() | String.t(), number() | Decimal.t() | String.t()}
          | %{optional(atom() | String.t()) => term()}

  @doc "Mean Earth radius in kilometres used by every function here (and `near:`)."
  @spec earth_radius_km() :: float()
  def earth_radius_km, do: @earth_radius_km

  @doc """
  Distance between two points in `unit` (`:km` default, `:mi`, `:m`), or
  `nil` when either point lacks coordinates.
  """
  @spec haversine(point(), point(), unit()) :: float() | nil
  def haversine(a, b, unit \\ :km) do
    with {lat1, lng1} <- coordinates(a), {lat2, lng2} <- coordinates(b) do
      dlat = radians(lat2 - lat1)
      dlng = radians(lng2 - lng1)

      h =
        :math.pow(:math.sin(dlat / 2), 2) +
          :math.cos(radians(lat1)) * :math.cos(radians(lat2)) * :math.pow(:math.sin(dlng / 2), 2)

      km = 2 * @earth_radius_km * :math.asin(min(1.0, :math.sqrt(h)))
      convert(km, unit)
    end
  end

  @doc "Whether `b` lies within `radius` (in `unit`) of `a`. `false` when either lacks coordinates."
  @spec within?(point(), point(), number(), unit()) :: boolean()
  def within?(a, b, radius, unit \\ :km) when is_number(radius) do
    case haversine(a, b, unit) do
      nil -> false
      distance -> distance <= radius
    end
  end

  @doc """
  `points` ordered nearest-first from `origin`; points without coordinates
  go last, in their original order. Returns `[{point, distance | nil}]`
  when `with_distance: true` is passed.
  """
  @spec sort_by_distance([point()], point(), keyword()) :: [point()] | [{point(), float() | nil}]
  def sort_by_distance(points, origin, opts \\ []) when is_list(points) do
    unit = Keyword.get(opts, :unit, :km)

    sorted =
      points
      |> Enum.map(&{&1, haversine(origin, &1, unit)})
      |> Enum.with_index()
      |> Enum.sort_by(fn {{_point, distance}, index} -> {is_nil(distance), distance, index} end)
      |> Enum.map(&elem(&1, 0))

    if Keyword.get(opts, :with_distance, false), do: sorted, else: Enum.map(sorted, &elem(&1, 0))
  end

  @doc """
  `{latitude, longitude}` as floats for any supported point, or `nil` when a
  coordinate is missing, unparseable or out of range.
  """
  @spec coordinates(point() | nil) :: {float(), float()} | nil
  def coordinates({lat, lng}), do: pair(lat, lng)

  def coordinates(%{latitude: lat, longitude: lng}), do: pair(lat, lng)
  def coordinates(%{"latitude" => lat, "longitude" => lng}), do: pair(lat, lng)
  def coordinates(_), do: nil

  defp pair(lat, lng) do
    with lat when is_float(lat) and lat >= -90 and lat <= 90 <- to_float(lat),
         lng when is_float(lng) and lng >= -180 and lng <= 180 <- to_float(lng) do
      {lat, lng}
    else
      _ -> nil
    end
  end

  defp to_float(n) when is_float(n), do: n
  # Out-of-range integers and Decimals never reach a float conversion (a
  # huge one overflows it, a NaN or infinite Decimal has none).
  defp to_float(n) when is_integer(n) and n >= -180 and n <= 180, do: n * 1.0
  defp to_float(n) when is_integer(n), do: nil

  defp to_float(%Decimal{} = d) do
    if Decimal.inf?(d) or Decimal.nan?(d) or Decimal.gt?(Decimal.abs(d), 180),
      do: nil,
      else: Decimal.to_float(d)
  rescue
    # Below the smallest float (1e-400): not a coordinate anyone meant.
    Decimal.Error -> nil
  end

  defp to_float(s) when is_binary(s) do
    case Float.parse(String.trim(s)) do
      {f, ""} -> f
      _ -> nil
    end
  end

  defp to_float(_), do: nil

  defp radians(deg), do: deg * :math.pi() / 180

  defp convert(km, :km), do: km
  defp convert(km, :m), do: km * 1000
  defp convert(km, :mi), do: km / @km_per_mile
end
