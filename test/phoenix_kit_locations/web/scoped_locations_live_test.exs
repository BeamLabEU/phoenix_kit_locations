defmodule PhoenixKitLocations.Web.ScopedLocationsLiveTest do
  @moduledoc """
  The `/admin/locations` pages for a user holding only the base `locations`
  permission (no `locations.manage_all`): the same pages, narrowed to the
  locations they own, with no client-supplied value reaching anyone else's.
  """

  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Paths
  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitLocations.Schemas.Space
  alias PhoenixKitLocations.Spaces
  alias PhoenixKitLocations.Test.Repo, as: TestRepo

  setup %{conn: conn} do
    user = fixture_user()
    other = fixture_user()

    conn =
      put_test_scope(
        conn,
        fake_scope(user_uuid: user.uuid, email: user.email, permissions: ["locations"])
      )

    {:ok, conn: conn, user: user, other: other}
  end

  defp owned_location(owner, attrs \\ %{}) do
    {:ok, location} =
      Locations.create_location(
        Map.merge(%{name: "Own #{System.unique_integer([:positive])}"}, attrs),
        owner_uuid: owner.uuid
      )

    location
  end

  defp floor(location, name) do
    {:ok, space} =
      Spaces.create_space(%{"location_uuid" => location.uuid, "kind" => "floor", "name" => name})

    space
  end

  describe "list" do
    test "shows only the user's own locations, with no owner controls",
         %{conn: conn, user: user, other: other} do
      mine = owned_location(user, %{name: "My Depot"})
      owned_location(other, %{name: "Their Depot"})
      fixture_location(%{name: "Global Depot"})

      {:ok, view, html} = live(conn, Paths.index())

      assert html =~ "My Depot"
      refute html =~ "Their Depot"
      refute html =~ "Global Depot"
      refute has_element?(view, "#owner-filter")
      assert has_element?(view, ~s(a[href="#{Paths.location_edit(mine.uuid)}"]))
      assert has_element?(view, ~s(a[href="#{Paths.location_new()}"]))
    end

    test "?owner= cannot widen the list", %{conn: conn, user: user} do
      owned_location(user, %{name: "My Depot"})
      fixture_location(%{name: "Global Depot"})

      {:ok, _view, html} = live(conn, "/en/admin/locations/?owner=global")

      assert html =~ "My Depot"
      refute html =~ "Global Depot"
    end

    test "deletes an own location and logs it", %{conn: conn, user: user} do
      mine = owned_location(user, %{name: "Short Lived"})

      {:ok, view, _html} = live(conn, Paths.index())

      render_click(view, "show_delete_confirm", %{"uuid" => mine.uuid, "type" => "location"})
      html = render_click(view, "delete_location", %{})

      refute html =~ "Short Lived"
      assert TestRepo.get(Location, mine.uuid) == nil
      assert_activity_logged("location.deleted", resource_uuid: mine.uuid, actor_uuid: user.uuid)
    end

    test "a forged delete of another account's or a global location deletes nothing",
         %{conn: conn, other: other} do
      theirs = owned_location(other, %{name: "Not Yours"})
      global = fixture_location(%{name: "Nobody's"})

      {:ok, view, _html} = live(conn, Paths.index())

      for uuid <- [theirs.uuid, global.uuid] do
        render_click(view, "show_delete_confirm", %{"uuid" => uuid, "type" => "location"})
        render_click(view, "delete_location", %{})
      end

      assert TestRepo.get(Location, theirs.uuid)
      assert TestRepo.get(Location, global.uuid)
    end
  end

  describe "types" do
    test "the Types tab and the type form redirect to the list", %{conn: conn} do
      type = fixture_location_type(%{name: "Warehouse"})

      for path <- [Paths.types(), Paths.type_new(), Paths.type_edit(type.uuid)] do
        assert {:error, {:live_redirect, %{to: to}}} = live(conn, path)
        assert to == Paths.index()
      end
    end

    test "a forged delete_location_type deletes nothing", %{conn: conn} do
      type = fixture_location_type(%{name: "Keep Me"})

      {:ok, view, _html} = live(conn, Paths.index())

      render_click(view, "show_delete_confirm", %{"uuid" => type.uuid, "type" => "location_type"})
      render_click(view, "delete_location_type", %{})

      assert Locations.get_location_type(type.uuid)
    end
  end

  describe "new" do
    test "renders without the owner card, Files card or internal notes", %{conn: conn} do
      {:ok, view, html} = live(conn, Paths.location_new())

      assert has_element?(view, "#header-title", "New")
      refute has_element?(view, "#location-owner-card")
      refute has_element?(view, "textarea[name='location[notes]']")
      refute html =~ "Floor plans, brochures"
    end

    test "creates the location owned by the current user, ignoring forged owner and notes",
         %{conn: conn, user: user, other: other} do
      {:ok, view, _html} = live(conn, Paths.location_new())

      assert {:error, {:live_redirect, %{to: to}}} =
               render_submit(view, "save", %{
                 "location" => %{
                   "name" => "Pickup Site",
                   "city" => "Tartu",
                   "notes" => "sneaky admin note",
                   "owner_uuid" => other.uuid
                 }
               })

      assert to == Paths.index()

      created = Locations.get_location_by(:name, "Pickup Site")
      assert created.owner_uuid == user.uuid
      assert created.city == "Tartu"
      assert created.notes == nil

      assert_activity_logged("location.created",
        resource_uuid: created.uuid,
        actor_uuid: user.uuid
      )
    end

    test "owner picker events are ignored", %{conn: conn, other: other} do
      {:ok, view, _html} = live(conn, Paths.location_new())

      render_change(view, "search_owner", %{"owner_search" => other.email})
      html = render_click(view, "pick_owner", %{"uuid" => other.uuid})

      refute html =~ other.email
    end

    test "the duplicate-address warning never names another account's location",
         %{conn: conn, user: user, other: other} do
      address = %{address_line_1: "7 Harbour St", city: "Narva", postal_code: "20101"}
      owned_location(other, Map.put(address, :name, "Their Harbour"))

      {:ok, view, _html} = live(conn, Paths.location_new())

      view
      |> form("#location-form",
        location: %{
          "name" => "N",
          "address_line_1" => "7 Harbour St",
          "city" => "Narva",
          "postal_code" => "20101"
        }
      )
      |> render_change()

      html = view |> element("input[name='location[postal_code]']") |> render_blur()
      refute html =~ "Their Harbour"

      owned_location(user, Map.put(address, :name, "My Harbour"))
      html = view |> element("input[name='location[postal_code]']") |> render_blur()
      assert html =~ "My Harbour"
    end
  end

  describe "edit" do
    test "updates an own location and keeps the Structure tab", %{conn: conn, user: user} do
      mine = owned_location(user, %{name: "Before"})

      {:ok, view, html} = live(conn, Paths.location_edit(mine.uuid))
      assert html =~ ~s(id="header-title">Before<)
      assert has_element?(view, ~s(a[href="#{Paths.location_structure(mine.uuid)}"]))

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#location-form", location: %{"name" => "After"})
               |> render_submit()

      assert to == Paths.index()
      reloaded = TestRepo.get!(Location, mine.uuid)
      assert reloaded.name == "After"
      assert reloaded.owner_uuid == user.uuid
    end

    test "another account's, a global or a malformed location redirects away",
         %{conn: conn, other: other} do
      theirs = owned_location(other)
      global = fixture_location()

      for uuid <- [theirs.uuid, global.uuid, "not-a-uuid"] do
        assert {:error, {:live_redirect, %{to: to}}} = live(conn, Paths.location_edit(uuid))
        assert to == Paths.index()
      end
    end

    test "ownership is re-checked on save", %{conn: conn, user: user, other: other} do
      mine = owned_location(user, %{name: "Reassigned"})

      {:ok, view, _html} = live(conn, Paths.location_edit(mine.uuid))
      {:ok, _} = Locations.set_location_owner(mine, other.uuid)

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#location-form", location: %{"name" => "Hijacked"})
               |> render_submit()

      assert to == Paths.index()
      assert TestRepo.get!(Location, mine.uuid).name == "Reassigned"
    end
  end

  describe "structure" do
    test "opens an own location's structure, without Files or internal notes",
         %{conn: conn, user: user} do
      mine = owned_location(user, %{name: "Own Warehouse"})
      space = floor(mine, "Ground")

      {:ok, view, html} = live(conn, Paths.location_structure(mine.uuid))
      assert html =~ "Own Warehouse"

      html = render_click(view, "select_space", %{"uuid" => space.uuid})

      refute html =~ "Internal notes (admin-only)"
      refute html =~ "Photos, layouts, anything specific to this space."
    end

    test "another account's structure redirects away", %{conn: conn, other: other} do
      theirs = owned_location(other)

      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, Paths.location_structure(theirs.uuid))

      assert to == Paths.index()
    end

    test "a forged rename or delete of another location's space changes nothing",
         %{conn: conn, user: user, other: other} do
      mine = owned_location(user)
      theirs = owned_location(other)
      their_space = floor(theirs, "Their Floor")

      {:ok, view, _html} = live(conn, Paths.location_structure(mine.uuid))

      render_click(view, "rename_space", %{"uuid" => their_space.uuid, "name" => "Hijacked"})
      render_click(view, "delete_space", %{"uuid" => their_space.uuid})
      render_click(view, "confirm_delete_space", %{})

      assert Spaces.get_space(their_space.uuid).name == "Their Floor"
    end
  end

  describe "organization members" do
    setup do
      org = fixture_user(%{account_type: "organization", organization_name: "Trinity Wood"})
      member = fixture_user(%{organization_uuid: org.uuid})
      teammate = fixture_user(%{organization_uuid: org.uuid})

      %{org: org, member: member, teammate: teammate}
    end

    defp member_conn(conn, user) do
      put_test_scope(
        conn,
        fake_scope(
          user_uuid: user.uuid,
          email: user.email,
          organization_uuid: user.organization_uuid,
          permissions: ["locations"]
        )
      )
    end

    test "a location a member creates belongs to the organization, and a teammate can edit it",
         %{conn: conn, org: org, member: member, teammate: teammate} do
      {:ok, view, _html} = live(member_conn(conn, member), Paths.location_new())

      {:error, {:live_redirect, _}} =
        render_submit(view, "save", %{"location" => %{"name" => "Shared Warehouse"}})

      created = Locations.get_location_by(:name, "Shared Warehouse")
      assert created.owner_uuid == org.uuid

      teammate_conn = member_conn(build_conn(), teammate)

      {:ok, _view, html} = live(teammate_conn, Paths.index())
      assert html =~ "Shared Warehouse"

      {:ok, view, _html} = live(teammate_conn, Paths.location_edit(created.uuid))

      {:error, {:live_redirect, _}} =
        view
        |> form("#location-form", location: %{"name" => "Renamed By Teammate"})
        |> render_submit()

      assert TestRepo.get!(Location, created.uuid).name == "Renamed By Teammate"
      assert TestRepo.get!(Location, created.uuid).owner_uuid == org.uuid
    end

    test "another organization's location stays out of reach",
         %{conn: conn, member: member} do
      rival_org = fixture_user(%{account_type: "organization", organization_name: "Rival"})
      {:ok, rival} = Locations.create_location(%{name: "Rival Yard"}, owner_uuid: rival_org.uuid)

      member_conn = member_conn(conn, member)

      {:ok, _view, html} = live(member_conn, Paths.index())
      refute html =~ "Rival Yard"

      assert {:error, {:live_redirect, %{to: to}}} =
               live(member_conn, Paths.location_edit(rival.uuid))

      assert to == Paths.index()
    end
  end

  describe "hardening" do
    test "file events are ignored and a forged attachment pointer is not stored",
         %{conn: conn, user: user} do
      mine = owned_location(user, %{name: "No Files"})
      {:ok, view, _html} = live(conn, Paths.location_edit(mine.uuid))

      for {event, params} <- [
            {"open_featured_image_picker", %{"scope" => "location"}},
            {"set_active_upload_scope", %{"scope" => "location"}},
            {"clear_featured_image", %{"scope" => "location"}},
            {"remove_file", %{"scope" => "location", "uuid" => UUIDv7.generate()}}
          ] do
        render_click(view, event, params)
      end

      assert {:error, {:live_redirect, _}} =
               render_submit(view, "save", %{
                 "location" => %{
                   "name" => "No Files",
                   "data" => %{
                     "files_folder_uuid" => UUIDv7.generate(),
                     "featured_image_uuid" => UUIDv7.generate()
                   }
                 }
               })

      data = TestRepo.get!(Location, mine.uuid).data
      refute Map.has_key?(data, "files_folder_uuid")
      refute Map.has_key?(data, "featured_image_uuid")
    end

    test "a forged toggle_type can't link a type the form didn't offer", %{conn: conn} do
      inactive = fixture_location_type(%{name: "Retired", status: "inactive"})

      {:ok, view, _html} = live(conn, Paths.location_new())
      render_click(view, "toggle_type", %{"uuid" => inactive.uuid})
      render_click(view, "toggle_type", %{"uuid" => UUIDv7.generate()})

      assert {:error, {:live_redirect, _}} =
               render_submit(view, "save", %{"location" => %{"name" => "Typed"}})

      created = Locations.get_location_by(:name, "Typed")
      assert Locations.linked_type_uuids(created.uuid) == []
    end

    test "Structure writes stop once the location is reassigned",
         %{conn: conn, user: user, other: other} do
      mine = owned_location(user)

      {:ok, view, _html} = live(conn, Paths.location_structure(mine.uuid))
      render_click(view, "open_add_root", %{})
      {:ok, _} = Locations.set_location_owner(mine, other.uuid)

      assert {:error, {:live_redirect, %{to: to}}} =
               render_submit(view, "create_space", %{
                 "space" => %{"kind" => "floor", "name" => "Too Late"}
               })

      assert to == Paths.index()
      assert TestRepo.get_by(Space, location_uuid: mine.uuid) == nil
    end

    test "malformed or foreign uuids in Structure events are ignored, not crashes",
         %{conn: conn, user: user} do
      mine = owned_location(user)
      {:ok, view, _html} = live(conn, Paths.location_structure(mine.uuid))

      render_click(view, "delete_space", %{"uuid" => "not-a-uuid"})
      render_click(view, "start_rename_space", %{"uuid" => "not-a-uuid"})
      render_click(view, "rename_space", %{"uuid" => "not-a-uuid", "name" => "X"})
      render_click(view, "open_add_child", %{"parent_uuid" => UUIDv7.generate()})

      refute has_element?(view, "#new-space-form")
    end

    test "create_space never stores a client-sent attachment pointer", %{user: user} do
      mine = owned_location(user)
      admin_conn = put_test_scope(build_conn(), fake_scope())

      {:ok, view, _html} = live(admin_conn, Paths.location_structure(mine.uuid))
      render_click(view, "open_add_root", %{})

      render_submit(view, "create_space", %{
        "space" => %{
          "kind" => "floor",
          "name" => "Forged",
          "data" => %{"files_folder_uuid" => UUIDv7.generate()}
        }
      })

      space = TestRepo.get_by!(Space, location_uuid: mine.uuid)
      refute Map.has_key?(space.data || %{}, "files_folder_uuid")
    end
  end
end
