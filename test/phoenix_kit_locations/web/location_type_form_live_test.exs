defmodule PhoenixKitLocations.Web.LocationTypeFormLiveTest do
  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Locations

  describe "new form" do
    test "renders the New Location Type heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/locations/types/new")
      assert html =~ "New Location Type"
    end

    test "submitting the form creates a type, redirects, and logs with actor_uuid",
         %{conn: conn} do
      scope = fake_scope()
      conn = put_test_scope(conn, scope)

      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form", location_type: %{"name" => "Warehouse"})
        |> render_submit()

      assert to == "/en/admin/locations/types"
      created = Locations.get_location_type_by_name("Warehouse")
      assert created

      assert_activity_logged("location_type.created",
        resource_uuid: created.uuid,
        actor_uuid: scope.user.uuid
      )
    end

    test "submit with blank name shows validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      rendered =
        view
        |> form("form", location_type: %{"name" => ""})
        |> render_submit()

      assert rendered =~ "can&#39;t be blank" or rendered =~ "can't be blank"
    end
  end

  describe "edit form" do
    test "renders existing type values", %{conn: conn} do
      type = fixture_location_type(%{name: "Original"})

      {:ok, _view, html} = live(conn, "/en/admin/locations/types/#{type.uuid}/edit")

      assert html =~ "Edit Original"
    end

    test "updating name persists the change", %{conn: conn} do
      type = fixture_location_type(%{name: "Original"})

      {:ok, view, _html} = live(conn, "/en/admin/locations/types/#{type.uuid}/edit")

      {:error, {:live_redirect, %{to: to}}} =
        view
        |> form("form", location_type: %{"name" => "Renamed"})
        |> render_submit()

      assert to == "/en/admin/locations/types"
      assert %{name: "Renamed"} = Locations.get_location_type(type.uuid)
    end

    test "edit with nonexistent UUID redirects with flash", %{conn: conn} do
      {:error, {:live_redirect, %{to: to, flash: flash}}} =
        live(conn, "/en/admin/locations/types/#{Ecto.UUID.generate()}/edit")

      assert to == "/en/admin/locations/types"
      assert flash["error"] =~ "Location type not found"
    end
  end

  describe "inline validation errors" do
    test "validate with blank name shows error before save", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      rendered =
        view
        |> form("form", location_type: %{"name" => ""})
        |> render_change()

      assert rendered =~ "can&#39;t be blank" or rendered =~ "can't be blank"
    end
  end

  describe "status select binding" do
    test "save with status=inactive persists", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      {:error, {:live_redirect, _}} =
        view
        |> form("form", location_type: %{"name" => "InactiveType", "status" => "inactive"})
        |> render_submit()

      assert %{status: "inactive"} = Locations.get_location_type_by_name("InactiveType")
    end
  end

  describe "phx-disable-with" do
    test "new-form submit button has phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/locations/types/new")
      assert html =~ ~s(phx-disable-with="Creating...")
    end

    test "edit-form submit button has phx-disable-with", %{conn: conn} do
      type = fixture_location_type(%{name: "X"})
      {:ok, _view, html} = live(conn, "/en/admin/locations/types/#{type.uuid}/edit")
      assert html =~ ~s(phx-disable-with="Saving...")
    end
  end

  describe "switch_language event" do
    test "switch_language event does not crash and rerenders", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      rendered = render_click(view, "switch_language", %{"lang" => "fr"})

      assert is_binary(rendered)
      assert rendered =~ "New Location Type"
    end
  end

  describe "update :error branch" do
    test "saving an edit with a too-long name re-renders with the validation error", %{
      conn: conn
    } do
      type = fixture_location_type(%{name: "Original"})
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/#{type.uuid}/edit")

      rendered =
        view
        |> form("form", location_type: %{"name" => String.duplicate("a", 300)})
        |> render_submit()

      assert rendered =~ "should be at most 255 character"
      assert Locations.get_location_type(type.uuid).name == "Original"
    end
  end

  describe "handle_info catch-all" do
    test "ignores unrelated messages without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/locations/types/new")

      send(view.pid, :unknown_msg_from_another_module)
      send(view.pid, {:something_we_dont_care_about, %{}})

      assert is_binary(render(view))
    end
  end
end
