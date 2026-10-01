defmodule PhoenixKitLocations.Web.Components.PlacePickerTest do
  @moduledoc """
  Drives `PlacePicker` LiveComponent events through
  `PlacePickerHarnessLive` (a minimal host — `PlacePicker` has no real
  production consumer yet, see the harness's moduledoc), mirroring how
  `ItemPickerEventsTest` drives `ItemPicker` through a real host LV in
  the catalogue module.

  `PlacePicker` is a LiveComponent, so every event below is sent to it
  through `with_target(view, "#harness-picker")` (or an element carrying
  `phx-target={@myself}`); `render_*(view, event, value)` alone would
  dispatch to the harness LiveView and miss the component. The location
  search is core's SearchPicker, whose dropdown the hook renders
  client-side: `search/2` sends the hook's event and returns the labels of
  the rows the component pushed back.
  """

  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Spaces

  defp harness_path(opts \\ []) do
    base = "/en/admin/locations/__test__/place-picker"

    params =
      opts
      |> Keyword.take([:location_type_uuid, :selected_space_uuid])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)

    case params do
      [] -> base
      _ -> "#{base}?#{Enum.join(params, "&")}"
    end
  end

  defp search_input, do: "#harness-picker-input"

  defp picker(view), do: with_target(view, "#harness-picker")

  defp search(view, query) do
    picker(view) |> render_hook("location_search", %{"q" => query, "limit" => 20})
    assert_push_event(view, "harness-picker:results", %{q: ^query, results: rows})
    Enum.map_join(rows, "\n", &"#{&1.label} #{Map.get(&1, :sublabel, "")}")
  end

  # What a click on a dropdown row sends; the component confirms with the
  # instance's staged event so the hook clears its input.
  defp select_location_option(view, location) do
    html = picker(view) |> render_click("select_location", %{"uuid" => location.uuid})
    assert_push_event(view, "harness-picker:staged", %{})
    html
  end

  defp fixture_space(location_uuid, attrs) do
    base = %{"location_uuid" => location_uuid, "kind" => "floor", "name" => "Space"}
    {:ok, space} = Spaces.create_space(Map.merge(base, attrs))
    space
  end

  describe "mount" do
    test "renders core's search picker for the location", %{conn: conn} do
      {:ok, view, html} = live(conn, harness_path())

      assert has_element?(view, ~s(#harness-picker-input[phx-hook="SearchPicker"]))

      assert has_element?(
               view,
               ~s(#harness-picker-input[data-results-event="harness-picker:results"])
             )

      assert html =~ "Search locations"
      refute html =~ "selected-place"
    end
  end

  describe "search + select a location" do
    test "typing a substring narrows matches to locations whose name contains it",
         %{conn: conn} do
      match = fixture_location(%{name: "Central Warehouse"})
      _decoy = fixture_location(%{name: "Downtown Office"})

      {:ok, view, _html} = live(conn, harness_path())

      rendered = search(view, "Warehouse")

      assert rendered =~ match.name
      refute rendered =~ "Downtown Office"
    end

    test "selecting a match swaps the combobox for its Space tree", %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})

      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      rendered = select_location_option(view, location)

      assert rendered =~ location.name
      refute has_element?(view, search_input())
      # No selection message yet — picking the *Location* alone isn't
      # a place selection; that requires a Space or "Use this location".
      refute has_element?(view, "#selected-place")
    end
  end

  describe "location_type_uuid filter" do
    test "excludes locations that don't have the given type assigned", %{conn: conn} do
      type = fixture_location_type()
      matching = fixture_location(%{name: "Match Loc"})
      {:ok, _} = Locations.add_location_type(matching.uuid, type.uuid)
      _other = fixture_location(%{name: "Other Loc"})

      {:ok, view, _html} = live(conn, harness_path(location_type_uuid: type.uuid))

      rendered = search(view, "Loc")

      assert rendered =~ "Match Loc"
      refute rendered =~ "Other Loc"
    end

    test "with no location_type_uuid, every active location matches", %{conn: conn} do
      type = fixture_location_type()
      a = fixture_location(%{name: "Loc A"})
      {:ok, _} = Locations.add_location_type(a.uuid, type.uuid)
      b = fixture_location(%{name: "Loc B"})

      {:ok, view, _html} = live(conn, harness_path())

      rendered = search(view, "Loc")

      assert rendered =~ a.name
      assert rendered =~ b.name
    end
  end

  describe "a forged select_location" do
    # The search only offers active locations of the given type; a
    # client-sent uuid must be held to the same filter, not just the owner.
    test "outside the type filter, or inactive, is ignored", %{conn: conn} do
      type = fixture_location_type()
      offered = fixture_location(%{name: "Typed Active"})
      {:ok, _} = Locations.add_location_type(offered.uuid, type.uuid)
      untyped = fixture_location(%{name: "Untyped Active"})
      inactive = fixture_location(%{name: "Typed Inactive", status: "inactive"})
      {:ok, _} = Locations.add_location_type(inactive.uuid, type.uuid)

      {:ok, view, _html} = live(conn, harness_path(location_type_uuid: type.uuid))

      for location <- [untyped, inactive] do
        html = picker(view) |> render_click("select_location", %{"uuid" => location.uuid})
        refute html =~ "Use this location"
      end

      html = select_location_option(view, offered)
      assert html =~ "Use this location"
    end

    test "of an inactive location is ignored without a type filter", %{conn: conn} do
      inactive = fixture_location(%{name: "Closed Site", status: "inactive"})
      {:ok, view, _html} = live(conn, harness_path())

      html = picker(view) |> render_click("select_location", %{"uuid" => inactive.uuid})
      refute html =~ "Use this location"
    end
  end

  describe "selecting a Space in the tree sends {:place_picker_select, ...} to the host" do
    test "a root-level node sends its location_uuid + space_uuid", %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      select_location_option(view, location)

      view
      |> element(~s([phx-click="select_space"][phx-value-uuid="#{floor.uuid}"]))
      |> render_click()

      assert has_element?(view, "#selected-place")
      assert view |> element("#selected-location-uuid") |> render() =~ location.uuid
      assert view |> element("#selected-space-uuid") |> render() =~ floor.uuid
    end

    test "a nested child is unreachable until its ancestor is expanded via toggle_space_node",
         %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      zone =
        fixture_space(location.uuid, %{
          "kind" => "zone",
          "name" => "Zone A",
          "parent_uuid" => floor.uuid
        })

      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      select_location_option(view, location)

      zone_select_selector = ~s([phx-click="select_space"][phx-value-uuid="#{zone.uuid}"])
      refute has_element?(view, zone_select_selector)

      view
      |> element(~s([phx-click="toggle_space_node"][phx-value-uuid="#{floor.uuid}"]))
      |> render_click()

      assert has_element?(view, zone_select_selector)
      view |> element(zone_select_selector) |> render_click()

      assert view |> element("#selected-location-uuid") |> render() =~ location.uuid
      assert view |> element("#selected-space-uuid") |> render() =~ zone.uuid
    end

    test "re-selecting a different Space updates the message instead of accumulating",
         %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})
      a = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor A"})
      b = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor B"})

      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      select_location_option(view, location)

      view
      |> element(~s([phx-click="select_space"][phx-value-uuid="#{a.uuid}"]))
      |> render_click()

      assert view |> element("#selected-space-uuid") |> render() =~ a.uuid

      view
      |> element(~s([phx-click="select_space"][phx-value-uuid="#{b.uuid}"]))
      |> render_click()

      assert view |> element("#selected-space-uuid") |> render() =~ b.uuid
    end
  end

  describe "\"Use this location\" (no specific space)" do
    test "sends space_uuid: nil", %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})

      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      select_location_option(view, location)

      view
      |> element(~s([phx-click="select_location_only"]))
      |> render_click()

      assert has_element?(view, "#selected-place")
      assert view |> element("#selected-location-uuid") |> render() =~ location.uuid
      assert view |> element("#selected-space-uuid") |> render() =~ "none"
    end
  end

  describe "update/2 seed-once behavior" do
    test "local selection highlight survives a parent re-render triggered by place_picker_select",
         %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})
      floor_a = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor A"})
      _floor_b = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor B"})

      # Harness passes selected_space_uuid={nil} (default from params) to the
      # picker. After the user selects Floor A, the harness re-renders (it
      # receives {:place_picker_select, ...}) and update/2 fires again with
      # selected_space_uuid: nil from the parent attrs. Without the seed-once
      # guard, that would reset the highlight to nil; with the fix, Floor A
      # stays highlighted.
      {:ok, view, _html} = live(conn, harness_path())
      search(view, "Central")
      select_location_option(view, location)

      # User picks Floor A — triggers send_selection, which sends
      # {:place_picker_select, ...} to the harness, causing a parent re-render
      # and a second call to update/2 with the parent's seed attrs.
      view
      |> element(~s([phx-click="select_space"][phx-value-uuid="#{floor_a.uuid}"]))
      |> render_click()

      rendered = render(view)

      # Floor A's selection was reported to the harness
      assert rendered =~ floor_a.uuid

      # The picker's tree still shows Floor A as highlighted (bg-primary/10)
      # — the local selected_space_uuid was NOT reset to nil by the re-render.
      assert rendered =~ "bg-primary/10"
    end

    test "seed selected_space_uuid is honoured on initial mount", %{conn: conn} do
      location = fixture_location(%{name: "Central Warehouse"})
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor Seed"})

      # Mount with a pre-seeded selected_space_uuid and select the matching
      # location so the tree renders.
      {:ok, view, _html} = live(conn, harness_path(selected_space_uuid: floor.uuid))
      search(view, "Central")
      select_location_option(view, location)

      rendered = render(view)

      # The seed highlight is visible in the tree.
      assert rendered =~ "bg-primary/10"
    end
  end
end
