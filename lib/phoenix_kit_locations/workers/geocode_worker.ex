defmodule PhoenixKitLocations.Workers.GeocodeWorker do
  @moduledoc """
  Background geocode of one location (`PhoenixKitLocations.Geocoding`).

  Runs on the `:default` queue, which every Oban install runs. Args:
  `location_uuid`, the address `fingerprint` and the `latitude` /
  `longitude` the row had at enqueue time; the write is refused when any of
  them no longer matches the row (see the Geocoding moduledoc), and the job
  is then cancelled rather than retried. A deleted location, a removed
  geocoder or a provider `:not_found` also end the job; any other geocoder
  error is retried with Oban's backoff.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 5,
    unique: [
      period: :infinity,
      # The expected coordinates are part of the key: a job queued for the
      # same address while the row held other coordinates is a different
      # job (it would be cancelled as stale), never the same one.
      keys: [:location_uuid, :fingerprint, :latitude, :longitude],
      states: [:available, :scheduled, :retryable]
    ]

  alias PhoenixKitLocations.Geocoding
  alias PhoenixKitLocations.Locations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"location_uuid" => uuid, "fingerprint" => fingerprint} = args}) do
    expect = %{
      fingerprint: fingerprint,
      latitude: Map.get(args, "latitude"),
      longitude: Map.get(args, "longitude")
    }

    opts =
      case Map.get(args, "actor_uuid") do
        actor when is_binary(actor) -> [expect: expect, actor_uuid: actor]
        _ -> [expect: expect]
      end

    with %{} = location <- Locations.get_location(uuid) || {:error, :location_not_found},
         true <- Geocoding.current?(location, expect) || {:error, :stale},
         {:ok, _location} <- Geocoding.geocode_now(location, opts) do
      :ok
    else
      {:error, reason} when reason in [:location_not_found, :stale, :no_geocoder, :no_address] ->
        {:cancel, reason}

      {:error, :not_found} ->
        {:cancel, :not_found}

      {:error, :invalid_result} ->
        {:cancel, :invalid_result}

      {:error, %Ecto.Changeset{}} ->
        {:cancel, :invalid_coordinates}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
