defmodule PhoenixKitLocations.Geocoder do
  @moduledoc """
  Behaviour for turning a location's address into coordinates.

  The module ships **no implementation and makes no HTTP call of its own**: a
  host that wants geocoding writes a module for its provider (Nominatim,
  Google, Mapbox, a local gazetteer …) and configures it:

      config :phoenix_kit_locations,
        geocoder: MyApp.LocationGeocoder,
        # or with options passed as `opts` to every call:
        # geocoder: {MyApp.LocationGeocoder, api_key: "…"},
        geocode_on_save: true

  With no `:geocoder` configured (the default) nothing is ever geocoded and
  coordinates are entered by hand. `:geocode_on_save` (default `false`)
  enqueues a background job (`PhoenixKitLocations.Workers.GeocodeWorker`)
  whenever a save changes the address or leaves the location without
  coordinates (and did not type them by hand); without it the host
  calls `PhoenixKitLocations.Geocoding.enqueue/2` or `geocode_now/2` itself.

  A provider `:not_found` is remembered for that address
  (`Location.geocode_miss`, the address fingerprint): saves don't ask again
  until the address changes, so coordinates can be left blank on purpose.
  `PhoenixKitLocations.Geocoding.geocode_now/2` always asks.

  **Inside a host transaction.** The job is inserted right after the save,
  in the caller's process. If the host wraps `create_location/2` or
  `update_location/3` in its own `Repo.transaction/1`, the insert joins that
  transaction: a database-level failure of the insert (e.g. Oban's tables
  missing) aborts the host's transaction even though the error is rescued
  here. Hosts that save inside their own transaction should have Oban
  installed, or call `Geocoding.enqueue/2` after their transaction commits
  (with `geocode_on_save` off).

  ## The callback

  `c:geocode/2` receives an `t:address/0` map and the configured options. It
  returns `{:ok, %{latitude: lat, longitude: lng}}` (numbers, `Decimal`s or
  numeric strings, in WGS 84 decimal degrees) or `{:error, reason}`. Return
  `{:error, :not_found}` when the provider has no match: the job treats that
  as final instead of retrying. Any other error is retried by the job.

      defmodule MyApp.LocationGeocoder do
        @behaviour PhoenixKitLocations.Geocoder

        @impl true
        def geocode(%{query: query}, opts) do
          case MyApp.Nominatim.search(query, opts) do
            {:ok, [%{"lat" => lat, "lon" => lon} | _]} -> {:ok, %{latitude: lat, longitude: lon}}
            {:ok, []} -> {:error, :not_found}
            {:error, reason} -> {:error, reason}
          end
        end
      end
  """

  @typedoc """
  What a geocoder receives. The stored fields (`country` is the ISO alpha-2
  code, `state` the `BeamLabCountries` subdivision id), their English display
  names, and `query`: the non-blank parts joined into one line
  (`"Main St 1, Tallinn, Harju County, 10111, Estonia"`), which is what most
  provider search APIs want.
  """
  @type address :: %{
          address_line_1: String.t() | nil,
          address_line_2: String.t() | nil,
          city: String.t() | nil,
          state: String.t() | nil,
          state_name: String.t() | nil,
          postal_code: String.t() | nil,
          country: String.t() | nil,
          country_name: String.t() | nil,
          query: String.t()
        }

  @type coordinate :: number() | Decimal.t() | String.t()
  @type result ::
          {:ok, %{required(:latitude) => coordinate(), required(:longitude) => coordinate()}}
          | {:error, term()}

  @callback geocode(address(), opts :: keyword()) :: result()

  @doc """
  The configured geocoder as `{module, opts}`, or `nil` when none is
  configured (the default). A configured module that is not loaded counts as
  none (and logs a warning), so a typo never crashes a save.
  """
  @spec configured() :: {module(), keyword()} | nil
  def configured do
    case Application.get_env(:phoenix_kit_locations, :geocoder) do
      nil -> nil
      {mod, opts} when is_atom(mod) and is_list(opts) -> loaded({mod, opts})
      mod when is_atom(mod) -> loaded({mod, []})
      other -> invalid(other)
    end
  end

  @doc "Whether a geocoder is configured."
  @spec enabled?() :: boolean()
  def enabled?, do: configured() != nil

  @doc "Whether saves enqueue a geocode job (`:geocode_on_save` and a configured geocoder)."
  @spec on_save?() :: boolean()
  def on_save? do
    Application.get_env(:phoenix_kit_locations, :geocode_on_save, false) == true and enabled?()
  end

  defp loaded({mod, _opts} = config) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :geocode, 2) do
      config
    else
      require Logger

      Logger.warning(
        "[PhoenixKitLocations] geocoder #{inspect(mod)} is not loaded or has no geocode/2; geocoding is off"
      )

      nil
    end
  end

  defp invalid(other) do
    require Logger

    Logger.warning(
      "[PhoenixKitLocations] invalid :geocoder config #{inspect(other)}; expected a module or {module, opts}"
    )

    nil
  end
end
