defmodule PhoenixKitLocations.Web.LocationStructureLiveTest do
  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Spaces

  # String-keyed attrs throughout — mirrors `test/spaces_test.exs`'s
  # `create_space/2` helper (and matches how `LocationStructureLive`
  # itself calls into `Spaces`). No default `attrs` — every call site
  # sets at least `kind`/`name` explicitly.
  defp fixture_space(location_uuid, attrs) do
    base = %{"location_uuid" => location_uuid, "kind" => "floor", "name" => "Space"}
    {:ok, space} = Spaces.create_space(Map.merge(base, attrs))
    space
  end

  defp positions_by_uuid(location_uuid) do
    location_uuid
    |> Spaces.list_for_location()
    |> Map.new(&{&1.uuid, &1.position})
  end

  defp structure_path(location), do: "/en/admin/locations/#{location.uuid}/structure"

  describe "mount" do
    test "renders the tabs and the location's Space tree", %{conn: conn} do
      location = fixture_location(%{name: "Warehouse A"})
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      _zone =
        fixture_space(location.uuid, %{
          "kind" => "zone",
          "name" => "Zone A",
          "parent_uuid" => floor.uuid
        })

      {:ok, view, html} = live(conn, structure_path(location))

      assert has_element?(view, ~s(#header-section[href="#{Paths.index()}"]), "Locations")
      assert has_element?(view, "#header-title", "Warehouse A")
      assert html =~ "Details"
      assert html =~ "Structure"
      assert has_element?(view, "a.tab-active", "Structure")
      assert has_element?(view, ~s(a[href="#{Paths.location_edit(location.uuid)}"]), "Details")

      assert html =~ "Floor 1"
      # Zone A is a child of Floor 1 — collapsed by default, so it must
      # not render until the parent node is expanded.
      refute html =~ "Zone A"
    end

    test "renders the empty-state message when the location has no spaces yet", %{conn: conn} do
      location = fixture_location(%{name: "Empty HQ"})
      {:ok, _view, html} = live(conn, structure_path(location))

      assert html =~ "No spaces yet."
    end

    test "mount with a nonexistent Location UUID redirects to index with flash", %{conn: conn} do
      {:error, {:live_redirect, %{to: to, flash: flash}}} =
        live(conn, "/en/admin/locations/#{Ecto.UUID.generate()}/structure")

      assert to == "/en/admin/locations"
      assert flash["error"] =~ "Location not found"
    end
  end

  describe "toggle_space_node — expand/collapse" do
    test "expands a collapsed parent to reveal its children, and collapses back", %{conn: conn} do
      location = fixture_location()
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      _zone =
        fixture_space(location.uuid, %{
          "kind" => "zone",
          "name" => "Zone A",
          "parent_uuid" => floor.uuid
        })

      {:ok, view, html} = live(conn, structure_path(location))
      refute html =~ "Zone A"

      expanded = render_click(view, "toggle_space_node", %{"uuid" => floor.uuid})
      assert expanded =~ "Zone A"

      collapsed = render_click(view, "toggle_space_node", %{"uuid" => floor.uuid})
      refute collapsed =~ "Zone A"
    end
  end

  describe "select_space — detail panel" do
    test "opens the panel scoped to the selected space and re-scopes on a new selection",
         %{conn: conn} do
      location = fixture_location()
      a = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor A"})
      b = fixture_space(location.uuid, %{"kind" => "room", "name" => "Room B"})

      {:ok, view, _html} = live(conn, structure_path(location))
      refute has_element?(view, "#space-detail-form")

      rendered_a = render_click(view, "select_space", %{"uuid" => a.uuid})
      assert has_element?(view, "#space-detail-form")
      assert rendered_a =~ "Attached Files"
      assert rendered_a =~ "No files attached yet."
      # The Files card + featured-image controls are scoped to the
      # selected space's own uuid — proves the detail panel shows
      # *that* space's files, not the location's or another space's.
      assert rendered_a =~ ~s(phx-value-scope="#{a.uuid}")
      refute rendered_a =~ ~s(phx-value-scope="#{b.uuid}")

      rendered_b = render_click(view, "select_space", %{"uuid" => b.uuid})
      assert rendered_b =~ ~s(phx-value-scope="#{b.uuid}")
      refute rendered_b =~ ~s(phx-value-scope="#{a.uuid}")
    end

    test "select_space with an unknown uuid is a safe no-op", %{conn: conn} do
      location = fixture_location()
      {:ok, view, _html} = live(conn, structure_path(location))

      rendered = render_click(view, "select_space", %{"uuid" => Ecto.UUID.generate()})
      refute has_element?(view, "#space-detail-form")
      assert Process.alive?(view.pid)
      assert is_binary(rendered)
    end
  end

  describe "create root/child space" do
    test "open_add_root then create_space persists a root space, logs activity, and auto-selects it",
         %{conn: conn} do
      location = fixture_location()
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      {:ok, view, _html} = live(conn, structure_path(location))

      render_click(view, "open_add_root", %{})
      assert has_element?(view, "#new-space-form")

      rendered =
        view
        |> form("#new-space-form", space: %{"kind" => "floor", "name" => "Ground Floor"})
        |> render_submit()

      refute has_element?(view, "#new-space-form")
      assert rendered =~ "Ground Floor"

      assert [created] = Spaces.list_for_location(location.uuid)
      assert created.name == "Ground Floor"
      assert created.kind == "floor"
      assert created.parent_uuid == nil

      assert_activity_logged("space.created",
        resource_uuid: created.uuid,
        actor_uuid: scope.user.uuid
      )

      # Auto-selected — the detail panel now shows the freshly created space.
      assert has_element?(view, "#space-detail-form")
    end

    test "create_space with a blank name shows a validation error and persists nothing",
         %{conn: conn} do
      location = fixture_location()
      {:ok, view, _html} = live(conn, structure_path(location))

      render_click(view, "open_add_root", %{})

      rendered =
        view
        |> form("#new-space-form", space: %{"kind" => "floor", "name" => ""})
        |> render_submit()

      assert rendered =~ "can&#39;t be blank" or rendered =~ "can't be blank"
      assert Spaces.list_for_location(location.uuid) == []
    end

    test "open_add_child then create_space nests under the parent and auto-expands it",
         %{conn: conn} do
      location = fixture_location()
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      {:ok, view, _html} = live(conn, structure_path(location))

      render_click(view, "open_add_child", %{"parent_uuid" => floor.uuid})
      assert has_element?(view, "#new-space-form")

      rendered =
        view
        |> form("#new-space-form", space: %{"kind" => "zone", "name" => "Zone A"})
        |> render_submit()

      # Auto-expanded — the new child is visible without a manual toggle.
      assert rendered =~ "Zone A"

      child =
        location.uuid
        |> Spaces.list_for_location()
        |> Enum.find(&(&1.name == "Zone A"))

      assert child.kind == "zone"
      assert child.parent_uuid == floor.uuid
    end

    test "cancel_add_space closes the form without creating anything", %{conn: conn} do
      location = fixture_location()
      {:ok, view, _html} = live(conn, structure_path(location))

      render_click(view, "open_add_root", %{})
      assert has_element?(view, "#new-space-form")

      render_click(view, "cancel_add_space", %{})
      refute has_element?(view, "#new-space-form")
      assert Spaces.list_for_location(location.uuid) == []
    end
  end

  describe "inline rename" do
    test "start_rename_space then rename_space persists the new name and logs activity",
         %{conn: conn} do
      location = fixture_location()
      space = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Old Name"})
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      {:ok, view, _html} = live(conn, structure_path(location))

      rendered = render_click(view, "start_rename_space", %{"uuid" => space.uuid})
      assert rendered =~ "rename-space-#{space.uuid}"

      renamed = render_submit(view, "rename_space", %{"uuid" => space.uuid, "name" => "New Name"})

      refute renamed =~ "rename-space-#{space.uuid}"
      assert renamed =~ "New Name"
      assert Spaces.get_space(space.uuid).name == "New Name"

      assert_activity_logged("space.updated",
        resource_uuid: space.uuid,
        actor_uuid: scope.user.uuid
      )
    end

    test "cancel_rename_space discards the in-progress edit", %{conn: conn} do
      location = fixture_location()
      space = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Keep Me"})

      {:ok, view, _html} = live(conn, structure_path(location))

      render_click(view, "start_rename_space", %{"uuid" => space.uuid})
      rendered = render_click(view, "cancel_rename_space", %{})

      refute rendered =~ "rename-space-#{space.uuid}"
      assert Spaces.get_space(space.uuid).name == "Keep Me"
    end

    test "renaming the currently-selected node keeps the detail panel in sync", %{conn: conn} do
      location = fixture_location()
      space = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Before"})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "select_space", %{"uuid" => space.uuid})

      rendered = render_submit(view, "rename_space", %{"uuid" => space.uuid, "name" => "After"})

      assert rendered =~ "After"
    end

    test "rename_space with an unknown uuid flashes not-found without crashing", %{conn: conn} do
      location = fixture_location()
      {:ok, view, _html} = live(conn, structure_path(location))

      rendered =
        render_submit(view, "rename_space", %{"uuid" => Ecto.UUID.generate(), "name" => "X"})

      assert rendered =~ "Space not found."
      assert Process.alive?(view.pid)
    end
  end

  describe "reorder — move up/down persists position" do
    test "move_space_down swaps position with the next root-level sibling", %{conn: conn} do
      location = fixture_location()

      f1 =
        fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1", "position" => 0})

      f2 =
        fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 2", "position" => 1})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "move_space_down", %{"uuid" => f1.uuid})

      positions = positions_by_uuid(location.uuid)
      assert positions[f2.uuid] == 0
      assert positions[f1.uuid] == 1
    end

    test "move_space_up swaps position with the previous root-level sibling", %{conn: conn} do
      location = fixture_location()

      f1 =
        fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1", "position" => 0})

      f2 =
        fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 2", "position" => 1})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "move_space_up", %{"uuid" => f2.uuid})

      positions = positions_by_uuid(location.uuid)
      assert positions[f2.uuid] == 0
      assert positions[f1.uuid] == 1
    end

    test "moving the first sibling further up is a no-op", %{conn: conn} do
      location = fixture_location()

      f1 =
        fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1", "position" => 0})

      f2 =
        fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 2", "position" => 1})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "move_space_up", %{"uuid" => f1.uuid})

      positions = positions_by_uuid(location.uuid)
      assert positions[f1.uuid] == 0
      assert positions[f2.uuid] == 1
    end

    test "moving the last sibling further down is a no-op", %{conn: conn} do
      location = fixture_location()

      f1 =
        fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1", "position" => 0})

      f2 =
        fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 2", "position" => 1})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "move_space_down", %{"uuid" => f2.uuid})

      positions = positions_by_uuid(location.uuid)
      assert positions[f1.uuid] == 0
      assert positions[f2.uuid] == 1
    end

    test "reorders children within a parent independently from root-level siblings",
         %{conn: conn} do
      location = fixture_location()

      floor =
        fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1", "position" => 5})

      r1 =
        fixture_space(location.uuid, %{
          "kind" => "room",
          "name" => "Room 1",
          "parent_uuid" => floor.uuid,
          "position" => 0
        })

      r2 =
        fixture_space(location.uuid, %{
          "kind" => "room",
          "name" => "Room 2",
          "parent_uuid" => floor.uuid,
          "position" => 1
        })

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "move_space_down", %{"uuid" => r1.uuid})

      positions = positions_by_uuid(location.uuid)
      assert positions[r2.uuid] == 0
      assert positions[r1.uuid] == 1
      # Untouched — proves the reorder is scoped to the (location, parent) group.
      assert positions[floor.uuid] == 5
    end
  end

  describe "delete_space — opens the confirmation modal without deleting" do
    test "shows the space's name and its descendant count, without deleting anything yet",
         %{conn: conn} do
      location = fixture_location()
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      zone =
        fixture_space(location.uuid, %{
          "kind" => "zone",
          "name" => "Zone A",
          "parent_uuid" => floor.uuid
        })

      _shelf =
        fixture_space(location.uuid, %{
          "kind" => "shelf",
          "name" => "Shelf 1",
          "parent_uuid" => zone.uuid
        })

      {:ok, view, _html} = live(conn, structure_path(location))
      rendered = render_click(view, "delete_space", %{"uuid" => floor.uuid})

      assert rendered =~ "Floor 1"
      assert rendered =~ "and its 2 descendants"
      assert rendered =~ "This cannot be undone."

      # Nothing is deleted until the modal's own confirm button fires.
      assert Spaces.get_space(floor.uuid) != nil
      assert Spaces.get_space(zone.uuid) != nil
    end

    test "omits the descendants phrase for a leaf space (0 descendants)", %{conn: conn} do
      location = fixture_location()
      space = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Solo Floor"})

      {:ok, view, _html} = live(conn, structure_path(location))
      rendered = render_click(view, "delete_space", %{"uuid" => space.uuid})

      assert rendered =~ "Solo Floor"
      assert rendered =~ "This cannot be undone."
      refute rendered =~ "descendants"

      assert Spaces.get_space(space.uuid) != nil
    end

    test "delete_space with an unknown uuid flashes not-found without opening the modal",
         %{conn: conn} do
      location = fixture_location()
      {:ok, view, _html} = live(conn, structure_path(location))

      rendered = render_click(view, "delete_space", %{"uuid" => Ecto.UUID.generate()})
      assert rendered =~ "Space not found."
      refute rendered =~ "This cannot be undone."
      assert Process.alive?(view.pid)
    end
  end

  describe "cancel_delete_space" do
    test "closes the modal without deleting anything", %{conn: conn} do
      location = fixture_location()
      space = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Keep Me"})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "delete_space", %{"uuid" => space.uuid})

      rendered = render_click(view, "cancel_delete_space", %{})

      refute rendered =~ "This cannot be undone."
      assert Spaces.get_space(space.uuid) != nil
    end
  end

  describe "confirm_delete_space — the only path that actually deletes" do
    test "hard-deletes and cascades to every descendant, logging only the root",
         %{conn: conn} do
      location = fixture_location()
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      zone =
        fixture_space(location.uuid, %{
          "kind" => "zone",
          "name" => "Zone A",
          "parent_uuid" => floor.uuid
        })

      shelf =
        fixture_space(location.uuid, %{
          "kind" => "shelf",
          "name" => "Shelf 1",
          "parent_uuid" => zone.uuid
        })

      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "delete_space", %{"uuid" => floor.uuid})
      rendered = render_click(view, "confirm_delete_space", %{})

      refute rendered =~ "Floor 1"
      assert Spaces.get_space(floor.uuid) == nil
      assert Spaces.get_space(zone.uuid) == nil
      assert Spaces.get_space(shelf.uuid) == nil

      assert_activity_logged("space.deleted",
        resource_uuid: floor.uuid,
        actor_uuid: scope.user.uuid
      )

      # Cascaded children are removed by the DB FK, not individually
      # logged — only the deleted root gets an activity row.
      refute_activity_logged("space.deleted", resource_uuid: zone.uuid)
      refute_activity_logged("space.deleted", resource_uuid: shelf.uuid)
    end

    test "deleting the currently-selected node clears the detail panel", %{conn: conn} do
      location = fixture_location()
      space = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Solo Floor"})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "select_space", %{"uuid" => space.uuid})
      assert has_element?(view, "#space-detail-form")

      render_click(view, "delete_space", %{"uuid" => space.uuid})
      render_click(view, "confirm_delete_space", %{})
      refute has_element?(view, "#space-detail-form")
    end

    test "deleting an ancestor of the selected node also clears the detail panel",
         %{conn: conn} do
      location = fixture_location()
      floor = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Floor 1"})

      zone =
        fixture_space(location.uuid, %{
          "kind" => "zone",
          "name" => "Zone A",
          "parent_uuid" => floor.uuid
        })

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "select_space", %{"uuid" => zone.uuid})
      assert has_element?(view, "#space-detail-form")

      render_click(view, "delete_space", %{"uuid" => floor.uuid})
      render_click(view, "confirm_delete_space", %{})
      refute has_element?(view, "#space-detail-form")
    end

    test "closes the modal after deleting", %{conn: conn} do
      location = fixture_location()
      space = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Gone Soon"})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "delete_space", %{"uuid" => space.uuid})

      rendered = render_click(view, "confirm_delete_space", %{})
      refute rendered =~ "This cannot be undone."
    end

    test "with nothing pending confirmation is a safe no-op", %{conn: conn} do
      location = fixture_location()
      {:ok, view, _html} = live(conn, structure_path(location))

      rendered = render_click(view, "confirm_delete_space", %{})
      assert is_binary(rendered)
      assert Process.alive?(view.pid)
    end
  end

  describe "detail panel — edit form" do
    test "update_space_form persists kind/status/notes changes", %{conn: conn} do
      location = fixture_location()
      space = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Editable"})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "select_space", %{"uuid" => space.uuid})

      view
      |> form("#space-detail-form",
        space: %{
          "kind" => "floor",
          "status" => "inactive",
          "name" => "Editable",
          "notes" => "internal note"
        }
      )
      |> render_submit()

      updated = Spaces.get_space(space.uuid)
      assert updated.status == "inactive"
      assert updated.notes == "internal note"
    end

    test "validate_space_form surfaces inline errors without persisting", %{conn: conn} do
      location = fixture_location()
      space = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Original"})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "select_space", %{"uuid" => space.uuid})

      rendered =
        view
        |> form("#space-detail-form",
          space: %{"kind" => "floor", "status" => "active", "name" => String.duplicate("a", 300)}
        )
        |> render_change()

      assert rendered =~ "should be at most 255 character"
      assert Spaces.get_space(space.uuid).name == "Original"
    end
  end

  describe "switch_language event" do
    test "does not crash and keeps rendering the detail panel", %{conn: conn} do
      location = fixture_location()
      space = fixture_space(location.uuid, %{"kind" => "floor", "name" => "Lang Test"})

      {:ok, view, _html} = live(conn, structure_path(location))
      render_click(view, "select_space", %{"uuid" => space.uuid})

      rendered = render_click(view, "switch_language", %{"lang" => "fr"})
      assert is_binary(rendered)
      assert rendered =~ "Lang Test"
    end
  end
end
