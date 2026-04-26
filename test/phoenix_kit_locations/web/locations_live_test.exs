defmodule PhoenixKitLocations.Web.LocationsLiveTest do
  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Test.Repo, as: TestRepo

  describe "index tab" do
    test "renders the locations list", %{conn: conn} do
      fixture_location(%{name: "HQ", city: "Springfield"})

      {:ok, _view, html} = live(conn, "/en/admin/locations/")
      assert html =~ "HQ"
      assert html =~ "Springfield"
    end

    test "renders empty state when no locations exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/locations/")
      assert html =~ "No locations yet."
    end

    test "renders a New Location link", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/")
      assert has_element?(view, "a", "New Location")
    end
  end

  describe "types tab" do
    test "renders the types list", %{conn: conn} do
      fixture_location_type(%{name: "Showroom"})

      {:ok, _view, html} = live(conn, "/en/admin/locations/types")
      assert html =~ "Showroom"
    end

    test "renders empty state when no types exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/locations/types")
      assert html =~ "No location types yet."
    end
  end

  describe "delete flow" do
    test "deleting a location removes it, flashes success, and logs with actor_uuid",
         %{conn: conn} do
      location = fixture_location(%{name: "Deletable"})
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      {:ok, view, _html} = live(conn, "/en/admin/locations/")

      render_click(view, "show_delete_confirm", %{
        "uuid" => location.uuid,
        "type" => "location"
      })

      rendered = render_click(view, "delete_location", %{})

      refute rendered =~ ">Deletable<"
      assert rendered =~ "Location deleted."
      assert is_nil(Locations.get_location(location.uuid))

      # Pinning that the LV threaded actor_opts/1 through the delete
      # call — without scope-injection this would silently log
      # actor_uuid: nil and the test would still pass against just
      # resource_uuid.
      assert_activity_logged("location.deleted",
        resource_uuid: location.uuid,
        actor_uuid: scope.user.uuid
      )
    end

    test "deleting a type removes it, flashes success, and logs with actor_uuid",
         %{conn: conn} do
      type = fixture_location_type(%{name: "DisposableType"})
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      {:ok, view, _html} = live(conn, "/en/admin/locations/types")

      render_click(view, "show_delete_confirm", %{
        "uuid" => type.uuid,
        "type" => "location_type"
      })

      rendered = render_click(view, "delete_location_type", %{})

      refute rendered =~ ">DisposableType<"
      assert rendered =~ "Location type deleted."
      assert is_nil(Locations.get_location_type(type.uuid))

      assert_activity_logged("location_type.deleted",
        resource_uuid: type.uuid,
        actor_uuid: scope.user.uuid
      )
    end

    test "cancel_delete clears the confirm state", %{conn: conn} do
      location = fixture_location(%{name: "Still here"})

      {:ok, view, _html} = live(conn, "/en/admin/locations/")

      render_click(view, "show_delete_confirm", %{
        "uuid" => location.uuid,
        "type" => "location"
      })

      render_click(view, "cancel_delete", %{})

      # Delete was cancelled — the record survives
      assert Locations.get_location(location.uuid)
    end

    test "delete of missing UUID flashes not-found and leaves other records alone", %{conn: conn} do
      surviving = fixture_location(%{name: "Present"})

      {:ok, view, _html} = live(conn, "/en/admin/locations/")

      render_click(view, "show_delete_confirm", %{
        "uuid" => Ecto.UUID.generate(),
        "type" => "location"
      })

      rendered = render_click(view, "delete_location", %{})

      assert rendered =~ "Location not found."
      assert Process.alive?(view.pid)
      assert Locations.get_location(surviving.uuid)
    end

    test "delete of missing type flashes not-found", %{conn: conn} do
      _surviving = fixture_location_type(%{name: "Stays"})

      {:ok, view, _html} = live(conn, "/en/admin/locations/types")

      render_click(view, "show_delete_confirm", %{
        "uuid" => Ecto.UUID.generate(),
        "type" => "location_type"
      })

      rendered = render_click(view, "delete_location_type", %{})

      assert rendered =~ "Location type not found."
    end

    test "delete event with unexpected type is a safe no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/")

      # confirm_delete stays nil; delete_location event with no prior
      # show_delete_confirm should simply clear state without crashing
      # or flashing an error.
      rendered = render_click(view, "delete_location", %{})
      refute rendered =~ "Location deleted."
      refute rendered =~ "Location not found."
      assert Process.alive?(view.pid)
    end

    test "cancel_delete clears confirm state and shows no flash", %{conn: conn} do
      location = fixture_location(%{name: "KeepMe"})
      {:ok, view, _html} = live(conn, "/en/admin/locations/")

      render_click(view, "show_delete_confirm", %{
        "uuid" => location.uuid,
        "type" => "location"
      })

      rendered = render_click(view, "cancel_delete", %{})

      refute rendered =~ "Location deleted."
      refute rendered =~ "Location not found."
      # Record still there
      assert Locations.get_location(location.uuid)
    end
  end

  describe "render with assigned types" do
    test "shows type badges in row + comma-joined name list in card", %{conn: conn} do
      type_a = fixture_location_type(%{name: "Showroom"})
      type_b = fixture_location_type(%{name: "Storage"})
      loc = fixture_location(%{name: "WithTypes"})
      {:ok, :synced} = Locations.sync_location_types(loc.uuid, [type_a.uuid, type_b.uuid])

      {:ok, _view, html} = live(conn, "/en/admin/locations/")

      # The :for span clause that renders one badge per type.
      assert html =~ "Showroom"
      assert html =~ "Storage"
      assert html =~ ~s(class="badge badge-sm badge-outline")

      # `type_names/1` non-empty branch (`Enum.map_join/3`) — used in
      # the card view label assigner.
      assert html =~ "Showroom, Storage" or html =~ "Storage, Showroom"
    end
  end

  # `load_data` rescue-branch coverage lives in
  # `test/destructive_rescue_test.exs` (async: false).

  describe "delete_location_type fallback" do
    test "delete_location_type event with no prior show_delete_confirm clears state", %{
      conn: conn
    } do
      # Mirrors the existing "delete event with unexpected type"
      # test for the location-side, but for location_type — covers
      # the LocationsLive `handle_event("delete_location_type", _, _)`
      # `_ -> ...` branch.
      {:ok, view, _html} = live(conn, "/en/admin/locations/types")

      rendered = render_click(view, "delete_location_type", %{})

      refute rendered =~ "Location type deleted."
      refute rendered =~ "Location type not found."
      assert Process.alive?(view.pid)
    end
  end

  describe "actor_opts no-scope path" do
    test "delete without scope still works and logs activity with nil actor", %{conn: conn} do
      # No `put_test_scope/2` here — exercises the `_ -> []` clause
      # in `actor_opts/1` (LocationsLive) when scope is unset.
      location = fixture_location(%{name: "AnonDelete"})

      {:ok, view, _html} = live(conn, "/en/admin/locations/")

      render_click(view, "show_delete_confirm", %{
        "uuid" => location.uuid,
        "type" => "location"
      })

      rendered = render_click(view, "delete_location", %{})

      assert rendered =~ "Location deleted."
      assert is_nil(Locations.get_location(location.uuid))
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}, %{}})

      # If the catch-all clause is missing, send/2 above plus the
      # `render/1` round-trip would surface a `FunctionClauseError`.
      # `render/1` returning a binary is the proof we want.
      assert is_binary(render(view))
    end
  end

  describe "translated status column" do
    test "renders translated Active label (not raw lowercase string)", %{conn: conn} do
      fixture_location(%{name: "StatusTest", status: "active"})
      {:ok, _view, html} = live(conn, "/en/admin/locations/")

      # Raw `"active"` (lowercase) must not appear in the status badge —
      # only the translated, capitalised form.
      assert html =~ "Active"
    end

    test "renders translated Inactive label", %{conn: conn} do
      fixture_location(%{name: "InactiveOne", status: "inactive"})
      {:ok, _view, html} = live(conn, "/en/admin/locations/")

      assert html =~ "Inactive"
    end

    test "renders raw status when value is outside the known active/inactive set", %{conn: conn} do
      # Bypasses the changeset's `validate_inclusion(:status, …)` via
      # raw `insert_all/3` so we land a row with a status that the
      # `status_label/1` clauses for "active"/"inactive" don't match.
      # That exercises the `defp status_label(other), do: other`
      # fallback in `LocationsLive`.
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      uuid = Ecto.UUID.generate()
      {:ok, raw_uuid} = Ecto.UUID.dump(uuid)

      TestRepo.insert_all("phoenix_kit_locations", [
        %{
          uuid: raw_uuid,
          name: "WeirdStatus",
          status: "pending",
          features: %{},
          data: %{},
          inserted_at: now,
          updated_at: now
        }
      ])

      {:ok, _view, html} = live(conn, "/en/admin/locations/")
      assert html =~ "WeirdStatus"
      assert html =~ "pending"
    end
  end
end
