defmodule PhoenixKitLocations.Web.LocationFormAddressTest do
  @moduledoc """
  The address block: country first, then state, city and postal code that
  follow it (dropdowns where the library has data, free text elsewhere), with
  ISO codes stored for country and state.
  """
  use PhoenixKitLocations.LiveCase

  import Ecto.Query

  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitLocations.Test.Repo

  defp change(view, location_params) do
    view |> form("#location-form", location: location_params) |> render_change()
  end

  # A row as it was saved before the dropdowns: typed text, past the changeset.
  defp legacy_location(attrs) do
    location = fixture_location(%{name: attrs.name})

    {1, _} =
      Repo.update_all(from(l in Location, where: l.uuid == ^location.uuid),
        set: attrs |> Map.delete(:name) |> Map.to_list()
      )

    location
  end

  test "the country is the first field of the address block", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/admin/locations/new")

    {country, _} = :binary.match(html, ~s(name="location[country]"))
    {line_1, _} = :binary.match(html, ~s(name="location[address_line_1]"))
    assert country < line_1
  end

  test "before a country is chosen state and city are plain text", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/locations/new")

    assert has_element?(view, ~s|select[name="location[country]"]|)
    assert has_element?(view, ~s|input[name="location[state]"]|)
    assert has_element?(view, ~s|input[name="location[city]"]|)
    refute has_element?(view, "#city-missing-hint")
  end

  test "a country with data offers its regions and cities, and a way to ask for more",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/locations/new")

    html = change(view, %{"country" => "EE"})

    assert has_element?(view, ~s|select[name="location[state]"] option[value="37"]|)
    assert has_element?(view, ~s|select[name="location[city]"] option[value="Tallinn"]|)
    assert html =~ "Region"
    assert has_element?(view, "#city-missing-hint", "contact the support team")
  end

  test "the labels follow the country", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/locations/new")

    assert change(view, %{"country" => "EE"}) =~ "Postal Code"

    html = change(view, %{"country" => "US"})
    assert html =~ "ZIP Code"
    assert html =~ ~r/>\s*State\s*</
  end

  test "in the US the city list follows the state", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/locations/new")

    change(view, %{"country" => "US"})
    assert has_element?(view, ~s|select[name="location[city]"] option[value="Los Angeles"]|)

    change(view, %{"state" => "NY"})
    assert has_element?(view, ~s|select[name="location[city]"] option[value="New York"]|)
    refute has_element?(view, ~s|select[name="location[city]"] option[value="Los Angeles"]|)
  end

  test "a new state clears the city picked for the old one", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/locations/new")

    change(view, %{"country" => "US"})
    change(view, %{"state" => "NY"})
    change(view, %{"city" => "New York"})

    assert has_element?(
             view,
             ~s|select[name="location[city]"] option[selected][value="New York"]|
           )

    change(view, %{"state" => "CA"})
    refute has_element?(view, ~s|select[name="location[city]"] option[selected]|)
  end

  test "a new country clears the state and city", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/locations/new")

    change(view, %{"country" => "EE"})
    change(view, %{"state" => "37"})
    change(view, %{"city" => "Tallinn"})
    assert has_element?(view, ~s|select[name="location[state]"] option[selected][value="37"]|)
    assert has_element?(view, ~s|select[name="location[city]"] option[selected][value="Tallinn"]|)

    change(view, %{"country" => "FI"})
    refute has_element?(view, ~s|select[name="location[state]"] option[selected]|)
    refute has_element?(view, ~s|select[name="location[city]"] option[selected]|)
  end

  test "saving stores the country and state codes and the city name", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/admin/locations/new")
    change(view, %{"country" => "EE"})
    change(view, %{"state" => "37"})

    {:error, {:live_redirect, _}} =
      view
      |> form("#location-form",
        location: %{"name" => "Tallinn HQ", "city" => "Tallinn", "address_line_1" => "1 Main St"}
      )
      |> render_submit()

    assert %{country: "EE", state: "37", city: "Tallinn"} =
             Locations.get_location_by(:name, "Tallinn HQ")
  end

  describe "rows saved before the dropdowns" do
    test "open on codes, and save them", %{conn: conn} do
      location =
        legacy_location(%{name: "Old HQ", country: "Estonia", state: "Harju", city: "Tallinn"})

      {:ok, view, _html} = live(conn, "/admin/locations/#{location.uuid}/edit")

      assert has_element?(view, ~s|select[name="location[country]"] option[selected][value="EE"]|)
      assert has_element?(view, ~s|select[name="location[state]"] option[selected][value="37"]|)

      assert has_element?(
               view,
               ~s|select[name="location[city]"] option[selected][value="Tallinn"]|
             )

      {:error, {:live_redirect, _}} = view |> form("#location-form") |> render_submit()

      assert %{country: "EE", state: "37"} = Locations.get_location(location.uuid)
    end

    test "keep a country the library does not know, selected and editable", %{conn: conn} do
      location =
        legacy_location(%{name: "Odd HQ", country: "Atlantis", state: "Deep", city: "Poseidonis"})

      {:ok, view, _html} = live(conn, "/admin/locations/#{location.uuid}/edit")

      assert has_element?(
               view,
               ~s|select[name="location[country]"] option[selected][value="Atlantis"]|
             )

      assert has_element?(view, ~s|input[name="location[state]"][value="Deep"]|)
      assert has_element?(view, ~s|input[name="location[city]"][value="Poseidonis"]|)

      {:error, {:live_redirect, _}} = view |> form("#location-form") |> render_submit()
      assert %{country: "Atlantis", state: "Deep"} = Locations.get_location(location.uuid)
    end

    test "keep a city outside the list as an extra option", %{conn: conn} do
      location = legacy_location(%{name: "Small HQ", country: "EE", city: "Kärdla"})

      {:ok, view, _html} = live(conn, "/admin/locations/#{location.uuid}/edit")

      assert has_element?(
               view,
               ~s|select[name="location[city]"] option[selected][value="Kärdla"]|
             )
    end
  end

  describe "duplicate warning" do
    setup do
      fixture_location(%{
        name: "Existing HQ",
        address_line_1: "123 Main St",
        city: "Tallinn",
        postal_code: "10111",
        country: "EE"
      })

      :ok
    end

    defp blur_postal_code(view) do
      view |> element(~s|input[name="location[postal_code]"]|) |> render_blur()
    end

    test "names a location in the same country", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/locations/new")
      change(view, %{"country" => "EE"})

      change(view, %{
        "address_line_1" => "123 Main St",
        "city" => "Tallinn",
        "postal_code" => "10111"
      })

      assert blur_postal_code(view) =~ "Similar address found at: Existing HQ"
    end

    test "ignores the same street in another country", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/locations/new")
      change(view, %{"country" => "FI"})

      change(view, %{
        "address_line_1" => "123 Main St",
        "city" => "Helsinki",
        "postal_code" => "10111"
      })

      refute blur_postal_code(view) =~ "Similar address found"
    end
  end
end
