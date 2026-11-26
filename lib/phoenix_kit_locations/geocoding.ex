defmodule PhoenixKitLocations.Geocoding do
  @moduledoc """
  Fills a location's `latitude` / `longitude` from its address through the
  host's `PhoenixKitLocations.Geocoder` (none by default — see its moduledoc
  for the config).

  Two entry points:

    * `enqueue/2` — inserts a `PhoenixKitLocations.Workers.GeocodeWorker`
      job (Oban, `:default` queue). `Locations.create_location/2` and
      `update_location/3` call it when `:geocode_on_save` is on and the save
      changed the address without also setting coordinates by hand.
    * `geocode_now/2` — calls the geocoder in the current process and writes
      the result (what the job runs; also usable from IEx or a host task).

  ## Stale writes

  A geocoder call can take seconds and a job can wait in the queue far
  longer, so the result is written only when it still describes the row.
  The job carries a fingerprint of the address it was enqueued for
  (`address_fingerprint/1`) and the coordinates the row had then; the write
  happens under a row lock and is refused with `{:error, :stale}` when either
  changed since. An address edited after enqueue is therefore never
  overwritten with the old address's coordinates, and coordinates typed by
  hand after enqueue are never overwritten by a late job.
  """

  require Logger

  alias PhoenixKitLocations.Geo
  alias PhoenixKitLocations.Geocoder
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitLocations.Workers.GeocodeWorker

  @type error ::
          :no_geocoder
          | :no_address
          | :not_found
          | :stale
          | :location_not_found
          | :invalid_result
          | Ecto.Changeset.t()
          | term()

  @doc """
  The `t:PhoenixKitLocations.Geocoder.address/0` map handed to the geocoder.
  Country and subdivision names are English, whatever the caller's locale.
  """
  @spec address(Location.t()) :: Geocoder.address()
  def address(%Location{} = location) do
    {country_name, state_name} =
      Gettext.with_locale(PhoenixKitLocations.Gettext, "en", fn ->
        {Geo.country_name(location.country), state_name(location.country, location.state)}
      end)

    fields = %{
      address_line_1: blank_to_nil(location.address_line_1),
      address_line_2: blank_to_nil(location.address_line_2),
      city: blank_to_nil(location.city),
      state: blank_to_nil(location.state),
      state_name: state_name,
      postal_code: blank_to_nil(location.postal_code),
      country: blank_to_nil(location.country),
      country_name: country_name
    }

    query =
      [
        fields.address_line_1,
        fields.address_line_2,
        fields.city,
        state_name,
        fields.postal_code,
        country_name
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    Map.put(fields, :query, query)
  end

  @doc """
  Whether the location has enough address to geocode: a street line, a city
  or a postal code (a country alone would land every location on the
  country's centroid).
  """
  @spec geocodable?(Location.t()) :: boolean()
  def geocodable?(%Location{} = location) do
    Enum.any?([location.address_line_1, location.city, location.postal_code], &present?/1)
  end

  @doc """
  A short stable fingerprint of the address fields (`Location.address_fields/0`),
  trimmed and case-folded, so the job can tell whether the address it was
  enqueued for is still the row's address.
  """
  @spec address_fingerprint(Location.t() | map()) :: String.t()
  def address_fingerprint(location) do
    Location.address_fields()
    |> Enum.map_join(<<0>>, fn field ->
      location |> Map.get(field) |> to_string() |> String.trim() |> String.downcase()
    end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  @doc """
  Inserts a geocode job for the location. Returns `{:ok, job}`, or
  `{:error, :no_geocoder}` / `{:error, :no_address}` without inserting, or
  `{:error, reason}` when Oban refuses or is not running. Never raises.

  A duplicate (same location, same address, job not yet finished) is not
  inserted twice.
  """
  @spec enqueue(Location.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, error()}
  def enqueue(%Location{} = location, opts \\ []) do
    cond do
      not Geocoder.enabled?() -> {:error, :no_geocoder}
      not geocodable?(location) -> {:error, :no_address}
      true -> insert_job(location, opts)
    end
  end

  @doc false
  # The job changeset `enqueue/2` inserts; exposed for tests.
  @spec new_job(Location.t(), keyword()) :: Ecto.Changeset.t()
  def new_job(%Location{} = location, opts \\ []) do
    %{
      "location_uuid" => location.uuid,
      "fingerprint" => address_fingerprint(location),
      "latitude" => coordinate_arg(location.latitude),
      "longitude" => coordinate_arg(location.longitude)
    }
    |> maybe_put_actor(Keyword.get(opts, :actor_uuid))
    |> GeocodeWorker.new(Keyword.take(opts, [:scheduled_at, :schedule_in, :priority]))
  end

  defp insert_job(location, opts) do
    case Oban.insert(Keyword.get(opts, :oban, Oban), new_job(location, opts)) do
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e ->
      Logger.warning("[PhoenixKitLocations] geocode job not enqueued: #{Exception.message(e)}")
      {:error, :enqueue_failed}
  catch
    :exit, reason ->
      Logger.warning("[PhoenixKitLocations] geocode job not enqueued: #{inspect(reason)}")
      {:error, :enqueue_failed}
  end

  @doc """
  Enqueues a job for every location that has an address but no coordinates.
  Returns the number of jobs inserted. Accepts `list_locations/1`'s
  `:owner_uuid` / `:status` filters to narrow the batch.
  """
  @spec enqueue_missing(keyword()) :: non_neg_integer()
  def enqueue_missing(opts \\ []) do
    if Geocoder.enabled?() do
      opts
      |> Keyword.take([:owner_uuid, :status])
      |> Locations.list_locations()
      |> Enum.filter(&(is_nil(&1.latitude) and geocodable?(&1)))
      |> Enum.count(&match?({:ok, _}, enqueue(&1, opts)))
    else
      0
    end
  end

  @doc """
  Geocodes the location now and writes the coordinates.

  Options:

    * `:expect` — `%{fingerprint:, latitude:, longitude:}` the row must still
      match when the result is written (the job passes what it was enqueued
      with). Defaults to the location as given, so a caller holding a stale
      struct gets `{:error, :stale}` rather than writing over a newer address.
    * `:actor_uuid` — recorded on the `location.geocoded` activity entry.
  """
  @spec geocode_now(Location.t(), keyword()) :: {:ok, Location.t()} | {:error, error()}
  def geocode_now(%Location{} = location, opts \\ []) do
    expect = Keyword.get_lazy(opts, :expect, fn -> expectation(location) end)

    with {:ok, {mod, geo_opts}} <- configured_geocoder(),
         true <- geocodable?(location) || {:error, :no_address},
         {:ok, coords} <- call_geocoder(mod, location, geo_opts),
         {:ok, coords} <- normalize_result(coords) do
      Locations.write_geocoded_coordinates(location.uuid, coords, expect, opts)
    end
  end

  @doc false
  @spec expectation(Location.t()) :: map()
  def expectation(%Location{} = location) do
    %{
      fingerprint: address_fingerprint(location),
      latitude: location.latitude,
      longitude: location.longitude
    }
  end

  @doc false
  # Whether a locked row still matches what the geocode was started for.
  @spec current?(Location.t(), map()) :: boolean()
  def current?(%Location{} = row, %{fingerprint: fingerprint} = expect) do
    address_fingerprint(row) == fingerprint and
      same_coordinate?(row.latitude, Map.get(expect, :latitude)) and
      same_coordinate?(row.longitude, Map.get(expect, :longitude))
  end

  defp configured_geocoder do
    case Geocoder.configured() do
      nil -> {:error, :no_geocoder}
      config -> {:ok, config}
    end
  end

  defp call_geocoder(mod, location, geo_opts) do
    case mod.geocode(address(location), geo_opts) do
      {:ok, coords} -> {:ok, coords}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_result, other}}
    end
  end

  defp normalize_result(%{} = coords) do
    with {:ok, lat} <- to_decimal(Map.get(coords, :latitude, Map.get(coords, "latitude"))),
         {:ok, lng} <- to_decimal(Map.get(coords, :longitude, Map.get(coords, "longitude"))) do
      {:ok, %{latitude: lat, longitude: lng}}
    else
      _ -> {:error, :invalid_result}
    end
  end

  defp normalize_result(_), do: {:error, :invalid_result}

  defp to_decimal(value) when is_float(value), do: {:ok, Decimal.from_float(value)}
  defp to_decimal(nil), do: :error

  # Finite and within ±180 only: a provider's "NaN" or "Infinity" passes
  # `Decimal.cast/1` but raises in Ecto's cast inside the write.
  defp to_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} ->
        if Decimal.inf?(decimal) or Decimal.nan?(decimal) or
             Decimal.gt?(Decimal.abs(decimal), 180),
           do: :error,
           else: {:ok, decimal}

      :error ->
        :error
    end
  end

  defp same_coordinate?(nil, nil), do: true
  defp same_coordinate?(nil, _), do: false
  defp same_coordinate?(_, nil), do: false

  defp same_coordinate?(a, b) do
    with {:ok, a} <- to_decimal(a), {:ok, b} <- to_decimal(b) do
      Decimal.equal?(Decimal.round(a, 6), Decimal.round(b, 6))
    else
      _ -> false
    end
  end

  defp coordinate_arg(nil), do: nil
  defp coordinate_arg(%Decimal{} = d), do: Decimal.to_string(d, :normal)

  defp maybe_put_actor(args, actor) when is_binary(actor), do: Map.put(args, "actor_uuid", actor)
  defp maybe_put_actor(args, _), do: args

  defp state_name(country, state) when is_binary(country) and is_binary(state) do
    case Enum.find(Geo.subdivision_options(country, nil), fn {_label, id} -> id == state end) do
      {label, _id} -> label
      nil -> blank_to_nil(state)
    end
  rescue
    _ -> blank_to_nil(state)
  end

  defp state_name(_country, state), do: blank_to_nil(state)

  defp present?(value), do: blank_to_nil(value) != nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
