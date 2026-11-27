defmodule PhoenixKitLocations.GeocodingTest do
  # Application env (the geocoder config) is global: not async.
  use PhoenixKitLocations.DataCase, async: false

  use Oban.Testing, repo: PhoenixKitLocations.Test.Repo

  alias PhoenixKitLocations.Geocoder
  alias PhoenixKitLocations.Geocoding
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Workers.GeocodeWorker

  defmodule FakeGeocoder do
    @behaviour PhoenixKitLocations.Geocoder

    @impl true
    def geocode(address, opts) do
      send(Keyword.get(opts, :test_pid, self()), {:geocode_called, address})

      case :persistent_term.get({__MODULE__, :reply}, :default) do
        :default -> {:ok, %{latitude: 59.437, longitude: "24.7536"}}
        fun when is_function(fun, 1) -> fun.(address)
        reply -> reply
      end
    end
  end

  setup do
    previous =
      Application.get_all_env(:phoenix_kit_locations)
      |> Keyword.take([:geocoder, :geocode_on_save])

    Application.put_env(:phoenix_kit_locations, :geocoder, {FakeGeocoder, test_pid: self()})

    on_exit(fn ->
      :persistent_term.erase({FakeGeocoder, :reply})
      Application.delete_env(:phoenix_kit_locations, :geocoder)
      Application.delete_env(:phoenix_kit_locations, :geocode_on_save)
      for {k, v} <- previous, do: Application.put_env(:phoenix_kit_locations, k, v)
    end)

    :ok
  end

  defp reply(value), do: :persistent_term.put({FakeGeocoder, :reply}, value)

  defp flush_geocode_calls do
    receive do
      {:geocode_called, _} -> flush_geocode_calls()
    after
      0 -> :ok
    end
  end

  defp location(attrs \\ %{}) do
    {:ok, l} =
      Locations.create_location(
        Map.merge(
          %{name: "HQ", address_line_1: "Narva mnt 5", city: "Tallinn", country: "EE"},
          attrs
        )
      )

    l
  end

  defp start_oban do
    start_supervised!(
      {Oban, name: Oban, repo: Repo, testing: :manual, queues: false, plugins: false}
    )
  end

  describe "Geocoder config" do
    test "none by default" do
      Application.delete_env(:phoenix_kit_locations, :geocoder)
      assert Geocoder.configured() == nil
      refute Geocoder.on_save?()
    end

    test "a bare module or {module, opts}; an unloaded module counts as none" do
      Application.put_env(:phoenix_kit_locations, :geocoder, FakeGeocoder)
      assert Geocoder.configured() == {FakeGeocoder, []}

      Application.put_env(:phoenix_kit_locations, :geocoder, Nope.NotAModule)
      assert Geocoder.configured() == nil

      Application.put_env(:phoenix_kit_locations, :geocoder, "junk")
      assert Geocoder.configured() == nil
    end

    test "on_save? needs both the flag and a geocoder" do
      refute Geocoder.on_save?()
      Application.put_env(:phoenix_kit_locations, :geocode_on_save, true)
      assert Geocoder.on_save?()
      Application.delete_env(:phoenix_kit_locations, :geocoder)
      refute Geocoder.on_save?()
    end
  end

  describe "address/1" do
    test "builds a one-line query with English names" do
      address = Geocoding.address(location())
      assert address.country == "EE"
      assert address.country_name == "Estonia"
      assert address.query == "Narva mnt 5, Tallinn, Estonia"
    end

    test "geocodable? needs more than a country" do
      refute Geocoding.geocodable?(location(%{address_line_1: nil, city: nil}))
      assert Geocoding.geocodable?(location(%{address_line_1: nil}))
    end
  end

  describe "geocode_now/2" do
    test "writes the coordinates and logs location.geocoded" do
      loc = location()
      assert {:ok, updated} = Geocoding.geocode_now(loc)
      assert_received {:geocode_called, %{query: "Narva mnt 5, Tallinn, Estonia"}}
      assert Decimal.equal?(updated.latitude, Decimal.new("59.437"))
      assert Decimal.equal?(updated.longitude, Decimal.new("24.7536"))
      assert_activity_logged("location.geocoded", resource_uuid: loc.uuid)
    end

    test "is refused when the address changed after the struct was loaded" do
      loc = location()
      {:ok, _} = Locations.update_location(loc, %{address_line_1: "Pärnu mnt 10"})

      assert {:error, :stale} = Geocoding.geocode_now(loc)
      assert Locations.get_location(loc.uuid).latitude == nil
    end

    test "is refused when coordinates were typed in the meantime" do
      loc = location()
      {:ok, _} = Locations.update_location(loc, %{latitude: "1", longitude: "2"})

      assert {:error, :stale} = Geocoding.geocode_now(loc)
      assert Decimal.equal?(Locations.get_location(loc.uuid).latitude, Decimal.new(1))
    end

    test "a NaN or infinite result is an invalid result, not a raise" do
      loc = location()

      for bad <- ["NaN", "Infinity", "-inf", Decimal.new("NaN")] do
        reply({:ok, %{latitude: bad, longitude: "0"}})
        assert {:error, :invalid_result} = Geocoding.geocode_now(loc)
      end

      assert Locations.get_location(loc.uuid).latitude == nil
    end

    test "passes geocoder errors through and rejects junk results" do
      loc = location()
      reply({:error, :not_found})
      assert {:error, :not_found} = Geocoding.geocode_now(loc)

      reply({:ok, %{latitude: "north"}})
      assert {:error, :invalid_result} = Geocoding.geocode_now(loc)

      reply({:ok, %{latitude: 123, longitude: 0}})
      assert {:error, %Ecto.Changeset{}} = Geocoding.geocode_now(loc)
    end

    test "without a geocoder or an address it does nothing" do
      assert {:error, :no_address} =
               Geocoding.geocode_now(location(%{address_line_1: nil, city: nil}))

      Application.delete_env(:phoenix_kit_locations, :geocoder)
      assert {:error, :no_geocoder} = Geocoding.geocode_now(location())
      refute_received {:geocode_called, _}
    end
  end

  describe "GeocodeWorker" do
    test "geocodes when the row still matches the job" do
      loc = location()
      args = Geocoding.new_job(loc).changes.args

      assert :ok = perform_job(GeocodeWorker, args)
      assert Locations.get_location(loc.uuid).latitude
    end

    test "cancels without calling the geocoder when the address changed since enqueue" do
      loc = location()
      args = Geocoding.new_job(loc).changes.args
      {:ok, _} = Locations.update_location(loc, %{city: "Tartu"})

      assert {:cancel, :stale} = perform_job(GeocodeWorker, args)
      refute_received {:geocode_called, _}
      assert Locations.get_location(loc.uuid).latitude == nil
    end

    test "cancels when hand-typed coordinates arrived since enqueue" do
      loc = location()
      args = Geocoding.new_job(loc).changes.args
      {:ok, _} = Locations.update_location(loc, %{latitude: "10", longitude: "20"})

      assert {:cancel, :stale} = perform_job(GeocodeWorker, args)
      assert Decimal.equal?(Locations.get_location(loc.uuid).latitude, Decimal.new(10))
    end

    test "an address edited while the geocoder runs is not overwritten" do
      loc = location()
      args = Geocoding.new_job(loc).changes.args

      reply(fn _address ->
        {:ok, _} = Locations.update_location(Locations.get_location(loc.uuid), %{city: "Tartu"})
        {:ok, %{latitude: 1, longitude: 1}}
      end)

      assert {:cancel, :stale} = perform_job(GeocodeWorker, args)
      assert Locations.get_location(loc.uuid).latitude == nil
    end

    test "junk, out-of-range results and a removed geocoder cancel instead of retrying" do
      loc = location()
      args = Geocoding.new_job(loc).changes.args

      reply({:ok, %{latitude: "north"}})
      assert {:cancel, :invalid_result} = perform_job(GeocodeWorker, args)

      reply({:ok, %{latitude: 95, longitude: 0}})
      assert {:cancel, :invalid_coordinates} = perform_job(GeocodeWorker, args)

      Application.delete_env(:phoenix_kit_locations, :geocoder)
      assert {:cancel, :no_geocoder} = perform_job(GeocodeWorker, args)
    end

    test "the geocoded activity entry carries the job's actor and mode auto" do
      loc = location()
      actor = Ecto.UUID.generate()
      args = Geocoding.new_job(loc, actor_uuid: actor).changes.args

      assert :ok = perform_job(GeocodeWorker, args)
      assert_activity_logged("location.geocoded", resource_uuid: loc.uuid, actor_uuid: actor)
    end

    test "a deleted location or a provider miss cancels; other errors retry" do
      loc = location()
      args = Geocoding.new_job(loc).changes.args

      reply({:error, :not_found})
      assert {:cancel, :not_found} = perform_job(GeocodeWorker, args)

      reply({:error, :timeout})
      assert {:error, :timeout} = perform_job(GeocodeWorker, args)

      {:ok, _} = Locations.delete_location(loc)
      assert {:cancel, :location_not_found} = perform_job(GeocodeWorker, args)
    end
  end

  describe "geocode on save" do
    setup do
      start_oban()
      :ok
    end

    test "off by default: saving never enqueues" do
      loc = location()
      refute_enqueued(worker: GeocodeWorker, args: %{"location_uuid" => loc.uuid})
    end

    test "on: a create with an address enqueues one job" do
      Application.put_env(:phoenix_kit_locations, :geocode_on_save, true)
      loc = location()

      assert_enqueued(
        worker: GeocodeWorker,
        args: %{"location_uuid" => loc.uuid, "fingerprint" => Geocoding.address_fingerprint(loc)}
      )
    end

    test "on: an address change enqueues, a name-only change does not" do
      loc = location(%{latitude: "59.1", longitude: "24.1"})
      Application.put_env(:phoenix_kit_locations, :geocode_on_save, true)

      {:ok, renamed} = Locations.update_location(loc, %{name: "Renamed"})
      refute_enqueued(worker: GeocodeWorker, args: %{"location_uuid" => loc.uuid})

      {:ok, moved} = Locations.update_location(renamed, %{city: "Tartu"})

      assert_enqueued(
        worker: GeocodeWorker,
        args: %{
          "location_uuid" => loc.uuid,
          "fingerprint" => Geocoding.address_fingerprint(moved)
        }
      )
    end

    # The form's hint: "Leave blank to look them up from the address after saving."
    test "on: a save that leaves the coordinates blank enqueues, even without an address change" do
      loc = location()
      Application.put_env(:phoenix_kit_locations, :geocode_on_save, true)

      {:ok, _} = Locations.update_location(loc, %{name: "Renamed"})
      assert_enqueued(worker: GeocodeWorker, args: %{"location_uuid" => loc.uuid})
    end

    test "on: clearing the coordinates is not typing them, so the save enqueues" do
      loc = location(%{latitude: "59.1", longitude: "24.1"})
      Application.put_env(:phoenix_kit_locations, :geocode_on_save, true)

      {:ok, cleared} =
        Locations.update_location(loc, %{latitude: "", longitude: "", city: "Tartu"})

      assert cleared.latitude == nil

      assert_enqueued(
        worker: GeocodeWorker,
        args: %{
          "location_uuid" => loc.uuid,
          "fingerprint" => Geocoding.address_fingerprint(cleared)
        }
      )
    end

    test "on: coordinates typed in the same save win, so nothing is enqueued" do
      Application.put_env(:phoenix_kit_locations, :geocode_on_save, true)
      loc = location(%{latitude: "59.1", longitude: "24.1"})
      refute_enqueued(worker: GeocodeWorker, args: %{"location_uuid" => loc.uuid})
    end

    test "on: a save from an old struct enqueues for what the row holds, not the struct" do
      loc = location()
      Application.put_env(:phoenix_kit_locations, :geocode_on_save, true)

      # The row was geocoded after `loc` was loaded (by a job, or another
      # editor typing coordinates).
      {:ok, _} =
        Locations.write_geocoded_coordinates(
          loc.uuid,
          %{latitude: 1, longitude: 2},
          Geocoding.expectation(loc)
        )

      # The old struct still says "no coordinates"; this save moves the city.
      {:ok, returned} = Locations.update_location(loc, %{city: "Tartu"})
      row = Locations.get_location(loc.uuid)
      # What the caller gets back holds the row's coordinates too.
      assert Decimal.equal?(returned.latitude, row.latitude)

      assert [job] = all_enqueued(worker: GeocodeWorker)
      assert job.args["fingerprint"] == Geocoding.address_fingerprint(row)
      assert Decimal.equal?(Decimal.new(job.args["latitude"]), Decimal.new(1))

      # So the job writes the new address's coordinates instead of being
      # cancelled as stale (which left Tartu with the old address's).
      reply({:ok, %{latitude: 58.378, longitude: 26.729}})
      assert :ok = perform_job(GeocodeWorker, job.args)
      assert Decimal.equal?(Locations.get_location(loc.uuid).latitude, Decimal.new("58.378"))
    end

    test "on: a field another session saved since the struct was loaded is the row's, not the struct's" do
      loc = location()

      {:ok, _} =
        Locations.update_location(Locations.get_location(loc.uuid), %{postal_code: "10111"})

      Application.put_env(:phoenix_kit_locations, :geocode_on_save, true)

      {:ok, _} = Locations.update_location(loc, %{city: "Tartu"})
      row = Locations.get_location(loc.uuid)

      assert [job] = all_enqueued(worker: GeocodeWorker)
      assert job.args["fingerprint"] == Geocoding.address_fingerprint(row)
    end

    test "a queued job for the same address but other expected coordinates does not swallow a new one" do
      loc = location()
      assert {:ok, _} = Geocoding.enqueue(loc)
      # Same address, the row now holds coordinates: a different job.
      assert {:ok, _} =
               Geocoding.enqueue(%{loc | latitude: Decimal.new(1), longitude: Decimal.new(2)})

      # The exact same job is still deduplicated.
      assert {:ok, %{conflict?: true}} = Geocoding.enqueue(loc)
      assert length(all_enqueued(worker: GeocodeWorker)) == 2
    end

    test "on: a :not_found is remembered for that address, so later saves don't ask again" do
      loc = location()
      reply({:error, :not_found})
      assert {:error, :not_found} = Geocoding.geocode_now(loc)
      assert Locations.get_location(loc.uuid).geocode_miss == Geocoding.address_fingerprint(loc)

      Application.put_env(:phoenix_kit_locations, :geocode_on_save, true)

      # Blank on purpose: a rename asks nobody.
      {:ok, renamed} = Locations.update_location(loc, %{name: "Renamed"})
      refute_enqueued(worker: GeocodeWorker, args: %{"location_uuid" => loc.uuid})

      # A new address asks again.
      {:ok, moved} = Locations.update_location(renamed, %{city: "Tartu"})

      assert_enqueued(
        worker: GeocodeWorker,
        args: %{
          "location_uuid" => loc.uuid,
          "fingerprint" => Geocoding.address_fingerprint(moved)
        }
      )

      # Missing-batch skips a remembered miss.
      Application.delete_env(:phoenix_kit_locations, :geocode_on_save)
      other = location(%{name: "Other"})
      assert {:error, :not_found} = Geocoding.geocode_now(other)

      refute Enum.any?(
               all_enqueued(worker: GeocodeWorker),
               &(&1.args["location_uuid"] == other.uuid)
             )

      Geocoding.enqueue_missing()

      refute Enum.any?(
               all_enqueued(worker: GeocodeWorker),
               &(&1.args["location_uuid"] == other.uuid)
             )
    end

    test "clearing typed coordinates asks again, even for a remembered miss" do
      loc = location()
      reply({:error, :not_found})
      assert {:error, :not_found} = Geocoding.geocode_now(loc)
      {:ok, typed} = Locations.update_location(loc, %{latitude: "1", longitude: "2"})
      Application.put_env(:phoenix_kit_locations, :geocode_on_save, true)

      {:ok, _} = Locations.update_location(typed, %{latitude: "", longitude: ""})
      assert_enqueued(worker: GeocodeWorker, args: %{"location_uuid" => loc.uuid})
    end

    test "a stale miss inside a host transaction does not doom it" do
      loc = location()

      reply(fn _ ->
        {:ok, _} = Locations.update_location(Locations.get_location(loc.uuid), %{city: "Tartu"})
        {:error, :not_found}
      end)

      assert {:ok, :host_work_done} =
               Repo.transaction(fn ->
                 assert {:error, :not_found} = Geocoding.geocode_now(loc)
                 :host_work_done
               end)
    end

    test "geocode_now still asks for a remembered miss, and a hit clears it" do
      loc = location()
      reply({:error, :not_found})
      assert {:error, :not_found} = Geocoding.geocode_now(loc)
      flush_geocode_calls()

      reply(:default)
      assert {:ok, found} = Geocoding.geocode_now(Locations.get_location(loc.uuid))
      assert_received {:geocode_called, _}
      assert found.geocode_miss == nil
      assert Locations.get_location(loc.uuid).geocode_miss == nil
    end

    test "a miss for an address the row no longer has is not recorded" do
      loc = location()

      reply(fn _ ->
        {:ok, _} = Locations.update_location(Locations.get_location(loc.uuid), %{city: "Tartu"})
        {:error, :not_found}
      end)

      assert {:error, :not_found} = Geocoding.geocode_now(loc)
      assert Locations.get_location(loc.uuid).geocode_miss == nil
    end

    test "enqueue_missing/1 queues every geocodable location without coordinates" do
      _no_address = location(%{name: "A", address_line_1: nil, city: nil})
      _has_coords = location(%{name: "B", latitude: "1", longitude: "1"})
      missing = location(%{name: "C"})

      assert Geocoding.enqueue_missing() == 1
      assert_enqueued(worker: GeocodeWorker, args: %{"location_uuid" => missing.uuid})
    end
  end

  test "enqueue without Oban running returns an error instead of raising" do
    assert {:error, _} = Geocoding.enqueue(location())
  end
end
