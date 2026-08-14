defmodule PhoenixKitLocations.Web.LocationFormLiveTest do
  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Locations

  describe "new form" do
    test "renders the New Location heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/locations/new")
      assert html =~ "New Location"
      assert html =~ "Address"
      assert html =~ "Contact"
      assert html =~ "Features &amp; Amenities"
    end

    test "submitting the form creates a location, redirects, and logs with actor_uuid",
         %{conn: conn} do
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("#location-form", location: %{"name" => "Fresh HQ", "city" => "Berlin"})
        |> render_submit()

      assert to == "/en/admin/locations"
      created = Locations.get_location_by(:name, "Fresh HQ")
      assert %{name: "Fresh HQ", city: "Berlin"} = created

      assert_activity_logged("location.created",
        resource_uuid: created.uuid,
        actor_uuid: scope.user.uuid
      )
    end

    test "submit with missing name shows validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      rendered =
        view
        |> form("#location-form", location: %{"name" => ""})
        |> render_submit()

      assert rendered =~ "can&#39;t be blank" or rendered =~ "can't be blank"
    end

    test "invalid email produces field error on submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      rendered =
        view
        |> form("#location-form",
          location: %{"name" => "X", "email" => "bad"}
        )
        |> render_submit()

      assert rendered =~ "valid email"
    end
  end

  describe "edit form" do
    test "renders existing location values", %{conn: conn} do
      location = fixture_location(%{name: "Original", city: "Oldtown"})

      {:ok, _view, html} = live(conn, "/en/admin/locations/#{location.uuid}/edit")

      assert html =~ "Edit Original"
      assert html =~ "value=\"Oldtown\""
    end

    test "updating fields persists changes, redirects, and logs with actor_uuid",
         %{conn: conn} do
      location = fixture_location(%{name: "Original", city: "Oldtown"})
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      {:ok, view, _html} = live(conn, "/en/admin/locations/#{location.uuid}/edit")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("#location-form",
          location: %{"name" => "Original", "city" => "Newcity"}
        )
        |> render_submit()

      assert to == "/en/admin/locations"
      assert %{city: "Newcity"} = Locations.get_location(location.uuid)

      assert_activity_logged("location.updated",
        resource_uuid: location.uuid,
        actor_uuid: scope.user.uuid
      )
    end

    test "edit with nonexistent UUID redirects to index with flash", %{conn: conn} do
      {:error, {:live_redirect, %{to: to, flash: flash}}} =
        live(conn, "/en/admin/locations/#{Ecto.UUID.generate()}/edit")

      assert to == "/en/admin/locations"
      assert flash["error"] =~ "Location not found"
    end
  end

  describe "type toggling" do
    test "clicking a type badge toggles it", %{conn: conn} do
      fixture_location_type(%{name: "Showroom"})
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      # Toggle "Showroom" on
      type = Locations.get_location_type_by_name("Showroom")

      render_click(view, "toggle_type", %{"uuid" => type.uuid})

      # Second toggle turns it off — both should not crash
      render_click(view, "toggle_type", %{"uuid" => type.uuid})

      assert Process.alive?(view.pid)
    end
  end

  describe "feature toggling" do
    test "toggle on then off cleanly persists empty features map", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      # On
      render_click(view, "toggle_feature", %{"key" => "wifi"})
      # Off
      render_click(view, "toggle_feature", %{"key" => "wifi"})

      {:error, {:live_redirect, _}} =
        view
        |> form("#location-form", location: %{"name" => "ToggledTwice"})
        |> render_submit()

      location = Locations.get_location_by(:name, "ToggledTwice")
      # After toggle on + off, the key is present but false
      assert Map.get(location.features, "wifi") in [false, nil]
    end

    test "persists features through save", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      render_click(view, "toggle_feature", %{"key" => "parking"})
      render_click(view, "toggle_feature", %{"key" => "wifi"})

      {:error, {:live_redirect, _}} =
        view
        |> form("#location-form", location: %{"name" => "Feature HQ"})
        |> render_submit()

      location = Locations.get_location_by(:name, "Feature HQ")
      assert location.features["parking"] == true
      assert location.features["wifi"] == true
      assert Map.get(location.features, "cctv", false) == false
    end
  end

  describe "status select binding" do
    test "save with status=inactive persists", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      {:error, {:live_redirect, _}} =
        view
        |> form("#location-form", location: %{"name" => "Inactive HQ", "status" => "inactive"})
        |> render_submit()

      assert %{status: "inactive"} = Locations.get_location_by(:name, "Inactive HQ")
    end
  end

  describe "type toggling (state assertions)" do
    test "toggle on then off restores empty assignment set", %{conn: conn} do
      type = fixture_location_type(%{name: "TypeX"})
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      render_click(view, "toggle_type", %{"uuid" => type.uuid})
      render_click(view, "toggle_type", %{"uuid" => type.uuid})

      # After an even number of toggles we're back to no types
      {:error, {:live_redirect, _}} =
        view
        |> form("#location-form", location: %{"name" => "NoType HQ"})
        |> render_submit()

      created = Locations.get_location_by(:name, "NoType HQ")
      assert Locations.linked_type_uuids(created.uuid) == []
    end

    test "toggle on + save persists the link", %{conn: conn} do
      type = fixture_location_type(%{name: "TypeOn"})
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      render_click(view, "toggle_type", %{"uuid" => type.uuid})

      {:error, {:live_redirect, _}} =
        view
        |> form("#location-form", location: %{"name" => "LinkedHQ"})
        |> render_submit()

      created = Locations.get_location_by(:name, "LinkedHQ")
      assert Locations.linked_type_uuids(created.uuid) == [type.uuid]
    end
  end

  describe "inline validation errors" do
    test "validate event with bad email surfaces error inline (before save)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      rendered =
        view
        |> form("#location-form", location: %{"name" => "X", "email" => "not-an-email"})
        |> render_change()

      assert rendered =~ "must be a valid email address"
    end

    test "validate event with too-long name surfaces length error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      rendered =
        view
        |> form("#location-form",
          location: %{"name" => String.duplicate("a", 300)}
        )
        |> render_change()

      assert rendered =~ "should be at most 255 character"
    end

    test "submit with blank name preserves user-typed city (changeset re-rendered)", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      rendered =
        view
        |> form("#location-form", location: %{"name" => "", "city" => "PreservedCity"})
        |> render_submit()

      # The city input still carries the user's value after the error
      assert rendered =~ ~s(value="PreservedCity")
    end
  end

  describe "phx-disable-with" do
    test "new-form submit button has phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/locations/new")
      assert html =~ ~s(phx-disable-with="Creating...")
    end

    test "edit-form submit button has phx-disable-with", %{conn: conn} do
      location = fixture_location(%{name: "X"})
      {:ok, _view, html} = live(conn, "/en/admin/locations/#{location.uuid}/edit")
      assert html =~ ~s(phx-disable-with="Saving...")
    end
  end

  describe "check_address / duplicate warning" do
    # Phoenix LV's `phx-blur` payload is `%{"key" => ..., "value" => ...}` —
    # NOT the form's serialized params. The handler reads from the changeset
    # (kept fresh by `phx-change="validate"`), so these tests seed the
    # changeset with a `render_change` first, then fire blur the same way a
    # real browser would.
    defp seed_address(view, address_line_1, city, postal_code) do
      view
      |> form("#location-form",
        location: %{
          "address_line_1" => address_line_1,
          "city" => city,
          "postal_code" => postal_code
        }
      )
      |> render_change()
    end

    defp blur_postal_code(view) do
      view
      |> element(~s|input[name="location[postal_code]"]|)
      |> render_blur()
    end

    test "fires warning when a matching address exists", %{conn: conn} do
      _existing =
        fixture_location(%{
          name: "Existing HQ",
          address_line_1: "123 Main St",
          city: "Springfield",
          postal_code: "62701"
        })

      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      seed_address(view, "123 Main St", "Springfield", "62701")
      rendered = blur_postal_code(view)

      assert rendered =~ "Similar address found at: Existing HQ"
    end

    test "no warning when no match", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      seed_address(view, "999 Nowhere Rd", "Anywhere", "00000")
      rendered = blur_postal_code(view)

      refute rendered =~ "Similar address found at"
    end

    test "warning clears on subsequent validate event", %{conn: conn} do
      _existing =
        fixture_location(%{
          name: "E",
          address_line_1: "12 Oak St",
          city: "C",
          postal_code: "99"
        })

      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      seed_address(view, "12 Oak St", "C", "99")
      warned = blur_postal_code(view)

      assert warned =~ "Similar address found at"

      cleared =
        view
        |> form("#location-form", location: %{"name" => "New"})
        |> render_change()

      refute cleared =~ "Similar address found at"
    end

    test "excludes self on edit (no warning when address matches own record)", %{conn: conn} do
      location =
        fixture_location(%{
          name: "Self",
          address_line_1: "77 Only St",
          city: "Onlytown",
          postal_code: "55"
        })

      {:ok, view, _html} = live(conn, "/en/admin/locations/#{location.uuid}/edit")

      # On :edit the loaded record already populates the changeset's data —
      # no need to re-seed via render_change before blur.
      rendered = blur_postal_code(view)

      refute rendered =~ "Similar address found at"
    end

    # Regression test for the bug the boss reported: "fill one field, click
    # into another, the first one clears." Root cause: `phx-blur` fires
    # `check_address` with payload `%{"key" => nil, "value" => "..."}`, but
    # the old handler pattern-matched on `%{"location" => params}`. With no
    # matching clause, the LV process crashed with FunctionClauseError,
    # auto-reconnected, and remounted the form — wiping every typed field.
    test "blur on an address field does not crash the LV and preserves typed fields",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      # User types a name and city, then blurs the address field. With the
      # old handler this triggered a FunctionClauseError → LV crash → reconnect.
      seed_address(view, "1 Reproduce Ave", "Reprocity", "00001")

      view
      |> form("#location-form",
        location: %{"name" => "RegressionHQ", "city" => "Reprocity"}
      )
      |> render_change()

      rendered = blur_postal_code(view)

      assert Process.alive?(view.pid), "blur on postal_code must not crash the LV"
      # Typed fields survive the blur (re-render uses up-to-date changeset).
      assert rendered =~ ~s(value="RegressionHQ")
      assert rendered =~ ~s(value="1 Reproduce Ave")
      assert rendered =~ ~s(value="Reprocity")
    end
  end

  describe "switch_language event" do
    test "switch_language event does not crash and rerenders", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      rendered = render_click(view, "switch_language", %{"lang" => "fr"})

      assert is_binary(rendered)
      # The form still renders after a language switch.
      assert rendered =~ "New Location"
    end
  end

  describe "update :error branch" do
    test "saving an edit with a too-long name re-renders with the validation error", %{
      conn: conn
    } do
      location = fixture_location(%{name: "Original"})
      {:ok, view, _html} = live(conn, "/en/admin/locations/#{location.uuid}/edit")

      rendered =
        view
        |> form("#location-form", location: %{"name" => String.duplicate("a", 300)})
        |> render_submit()

      assert rendered =~ "should be at most 255 character"
      # Record was not updated — original name preserved.
      assert Locations.get_location(location.uuid).name == "Original"
    end
  end

  describe "sync_types_and_redirect :error branch" do
    test "save redirects with warning flash when sync_location_types fails (FK violation)",
         %{conn: conn} do
      # An edit save with a stale linked_type_uuids state hits the
      # FK assoc_constraint inside sync_location_types and returns
      # {:error, :type_assignment_failed}. The LV's
      # `sync_types_and_redirect/3` `:error` clause flashes a warning
      # and redirects rather than crashing.
      location = fixture_location(%{name: "Stale"})
      {:ok, view, _html} = live(conn, "/en/admin/locations/#{location.uuid}/edit")

      bogus = Ecto.UUID.generate()
      render_click(view, "toggle_type", %{"uuid" => bogus})

      {:ok, _new_view, html} =
        view
        |> form("#location-form", location: %{"name" => "Stale"})
        |> render_submit()
        |> follow_redirect(conn, "/en/admin/locations")

      # Follow the live_redirect — the warning flash is replayed on
      # the index page via our flash-rendering test layout.
      assert html =~ "Saved but failed to update type assignments."
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}})

      assert is_binary(render(view))
    end
  end
end
