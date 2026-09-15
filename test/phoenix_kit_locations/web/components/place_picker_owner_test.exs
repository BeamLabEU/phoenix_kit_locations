defmodule PhoenixKitLocations.Web.Components.PlacePickerOwnerTest do
  @moduledoc "`PlacePicker`'s `:owner_uuid` attr: it narrows the search, and it is enforced on selection."

  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Locations

  @base "/en/admin/locations/__test__/place-picker"

  setup do
    owner = fixture_user()
    other = fixture_user()

    {:ok, mine} = Locations.create_location(%{name: "Site Mine"}, owner_uuid: owner.uuid)
    {:ok, theirs} = Locations.create_location(%{name: "Site Theirs"}, owner_uuid: other.uuid)
    global = fixture_location(%{name: "Site Global"})

    %{owner: owner, mine: mine, theirs: theirs, global: global}
  end

  defp search(view, query),
    do: view |> element("#harness-picker-input") |> render_change(%{"value" => query})

  test "without the attr every location is searchable", %{conn: conn} do
    {:ok, view, _html} = live(conn, @base)
    html = search(view, "Site")

    assert html =~ "Site Mine"
    assert html =~ "Site Theirs"
    assert html =~ "Site Global"
  end

  test "an owner uuid offers only that owner's locations", %{conn: conn, owner: owner} do
    {:ok, view, _html} = live(conn, "#{@base}?owner_uuid=#{owner.uuid}")
    html = search(view, "Site")

    assert html =~ "Site Mine"
    refute html =~ "Site Theirs"
    refute html =~ "Site Global"
  end

  test "nil offers only global locations", %{conn: conn} do
    {:ok, view, _html} = live(conn, "#{@base}?owner_uuid=none")
    html = search(view, "Site")

    assert html =~ "Site Global"
    refute html =~ "Site Mine"
    refute html =~ "Site Theirs"
  end

  test "a forged select_location outside the owner filter is ignored",
       %{conn: conn, owner: owner, mine: mine, theirs: theirs, global: global} do
    {:ok, view, _html} = live(conn, "#{@base}?owner_uuid=#{owner.uuid}")
    target = with_target(view, "#harness-picker")

    for location <- [theirs, global] do
      html = render_click(target, "select_location", %{"uuid" => location.uuid})
      refute html =~ location.name
    end

    html = render_click(target, "select_location", %{"uuid" => mine.uuid})
    assert html =~ "Site Mine"
    assert html =~ "Use this location"
  end

  test "a malformed select_location uuid is ignored, not a crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, @base)

    html =
      view
      |> with_target("#harness-picker")
      |> render_click("select_location", %{"uuid" => "not-a-uuid"})

    refute html =~ "Use this location"
  end
end
