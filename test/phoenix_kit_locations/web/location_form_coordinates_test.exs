defmodule PhoenixKitLocations.Web.LocationFormCoordinatesTest do
  use PhoenixKitLocations.LiveCase

  alias PhoenixKitLocations.Locations

  test "the Details tab offers latitude and longitude, and a save stores them", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/locations/new")
    assert has_element?(view, "#location-coordinates #location_latitude")
    assert has_element?(view, "#location-coordinates #location_longitude")

    {:error, {:live_redirect, _}} =
      view
      |> form("#location-form",
        location: %{"name" => "Geo HQ", "latitude" => "59.437", "longitude" => "24.7536"}
      )
      |> render_submit()

    loc = Locations.get_location_by(:name, "Geo HQ")
    assert Decimal.equal?(loc.latitude, Decimal.new("59.437"))
    assert Decimal.equal?(loc.longitude, Decimal.new("24.7536"))
  end

  test "a lone or out-of-range coordinate is a field error", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/locations/new")

    html =
      view
      |> form("#location-form", location: %{"name" => "X", "latitude" => "95"})
      |> render_submit()

    assert html =~ "must be between -90 and 90"
    assert html =~ "enter both latitude and longitude"
    assert Locations.get_location_by(:name, "X") == nil
  end

  test "editing keeps stored coordinates and can clear both", %{conn: conn} do
    location = fixture_location(%{name: "Pinned", latitude: "1.5", longitude: "2.5"})
    {:ok, view, html} = live(conn, "/admin/locations/#{location.uuid}/edit")
    assert html =~ ~s(value="1.500000") or html =~ ~s(value="1.5")

    {:error, {:live_redirect, _}} =
      view
      |> form("#location-form", location: %{"latitude" => "", "longitude" => ""})
      |> render_submit()

    assert %{latitude: nil, longitude: nil} = Locations.get_location(location.uuid)
  end
end
