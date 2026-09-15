defmodule PhoenixKitLocations.Web.LocationOwnerAdminLiveTest do
  @moduledoc "Ownership in the admin UI: the list's owner column and filter, and the form's owner card."

  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitLocations.Test.Repo, as: TestRepo

  defp owned_location(owner, attrs) do
    {:ok, location} = Locations.create_location(attrs, owner_uuid: owner.uuid)
    location
  end

  describe "list" do
    setup do
      owner = fixture_user()
      owned_location(owner, %{name: "Seller Warehouse"})
      fixture_location(%{name: "Shared Showroom"})
      %{owner: owner}
    end

    test "shows the owner's email, and Global for unowned rows", %{conn: conn, owner: owner} do
      {:ok, _view, html} = live(conn, "/en/admin/locations/")

      assert html =~ "Seller Warehouse"
      assert html =~ "Shared Showroom"
      assert html =~ owner.email
      assert html =~ "Global"
    end

    test "?owner=global and ?owner=owned filter the list", %{conn: conn} do
      {:ok, _view, global} = live(conn, "/en/admin/locations/?owner=global")
      assert global =~ "Shared Showroom"
      refute global =~ "Seller Warehouse"

      {:ok, _view, owned} = live(conn, "/en/admin/locations/?owner=owned")
      assert owned =~ "Seller Warehouse"
      refute owned =~ "Shared Showroom"
    end

    test "the filter buttons patch the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/")

      html = view |> element("#owner-filter-owned") |> render_click()

      assert_patch(view, "/en/admin/locations?owner=owned")
      refute html =~ "Shared Showroom"
    end
  end

  describe "form owner card" do
    setup %{conn: conn} do
      scope = fake_scope()
      %{conn: put_test_scope(conn, scope), scope: scope, owner: fixture_user()}
    end

    defp pick_owner(view, user) do
      view |> element("#owner-search-form") |> render_change(%{"owner_search" => user.email})
      view |> element(~s(#owner-matches button[phx-value-uuid="#{user.uuid}"])) |> render_click()
    end

    test "new: a picked owner is set on create", %{conn: conn, owner: owner} do
      {:ok, view, html} = live(conn, "/en/admin/locations/new")
      assert html =~ "No owner (global)"

      html = pick_owner(view, owner)
      assert html =~ owner.email

      {:error, {:live_redirect, _}} =
        view |> form("#location-form", location: %{"name" => "Picked"}) |> render_submit()

      assert Locations.get_location_by(:name, "Picked").owner_uuid == owner.uuid
    end

    test "new: without a pick the location is global", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      {:error, {:live_redirect, _}} =
        view |> form("#location-form", location: %{"name" => "Unpicked"}) |> render_submit()

      assert Locations.get_location_by(:name, "Unpicked").owner_uuid == nil
    end

    test "pick_owner ignores a uuid that isn't in the search results",
         %{conn: conn, owner: owner} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/new")

      html = render_click(view, "pick_owner", %{"uuid" => owner.uuid})

      refute html =~ owner.email
    end

    test "edit: shows the current owner, and changing it logs owner_changed",
         %{conn: conn, scope: scope, owner: owner} do
      new_owner = fixture_user()
      location = owned_location(owner, %{name: "Moving"})

      {:ok, view, html} = live(conn, "/en/admin/locations/#{location.uuid}/edit")
      assert html =~ owner.email

      pick_owner(view, new_owner)

      {:error, {:live_redirect, _}} =
        view |> form("#location-form", location: %{"name" => "Moving"}) |> render_submit()

      assert TestRepo.get!(Location, location.uuid).owner_uuid == new_owner.uuid

      assert_activity_logged("location.owner_changed",
        resource_uuid: location.uuid,
        actor_uuid: scope.user.uuid,
        metadata_has: %{"owner_from" => owner.uuid, "owner_to" => new_owner.uuid}
      )
    end

    test "edit: removing the owner makes the location global", %{conn: conn, owner: owner} do
      location = owned_location(owner, %{name: "Released"})

      {:ok, view, _html} = live(conn, "/en/admin/locations/#{location.uuid}/edit")
      html = view |> element("button", "Remove owner") |> render_click()
      assert html =~ "No owner (global)"

      {:error, {:live_redirect, _}} =
        view |> form("#location-form", location: %{"name" => "Released"}) |> render_submit()

      assert TestRepo.get!(Location, location.uuid).owner_uuid == nil
    end

    test "edit: saving without touching the owner logs no owner change",
         %{conn: conn, owner: owner} do
      location = owned_location(owner, %{name: "Untouched"})

      {:ok, view, _html} = live(conn, "/en/admin/locations/#{location.uuid}/edit")

      {:error, {:live_redirect, _}} =
        view |> form("#location-form", location: %{"name" => "Untouched 2"}) |> render_submit()

      assert TestRepo.get!(Location, location.uuid).owner_uuid == owner.uuid
      refute_activity_logged("location.owner_changed", resource_uuid: location.uuid)
    end
  end
end
