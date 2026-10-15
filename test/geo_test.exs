defmodule PhoenixKitLocations.GeoTest do
  use ExUnit.Case, async: true

  alias PhoenixKitLocations.Geo
  alias PhoenixKitLocations.Schemas.Location

  describe "normalize_country/1" do
    test "keeps a code, in any case" do
      assert Geo.normalize_country("EE") == "EE"
      assert Geo.normalize_country(" ee ") == "EE"
    end

    test "maps an alpha-3 code and names in several languages" do
      assert Geo.normalize_country("EST") == "EE"
      assert Geo.normalize_country("Estonia") == "EE"
      assert Geo.normalize_country("eesti") == "EE"
      assert Geo.normalize_country("Эстония") == "EE"
      assert Geo.normalize_country("日本") == "JP"
    end

    test "is nil for blank or unknown text" do
      assert Geo.normalize_country(nil) == nil
      assert Geo.normalize_country("  ") == nil
      assert Geo.normalize_country("Atlantis") == nil
    end
  end

  describe "normalize_subdivision/2" do
    test "maps a name or an id to the subdivision id" do
      assert Geo.normalize_subdivision("US", "New York") == "NY"
      assert Geo.normalize_subdivision("US", "ny") == "NY"
      assert Geo.normalize_subdivision("EE", "Harju") == "37"
    end

    test "is nil when the country has no such subdivision" do
      assert Geo.normalize_subdivision("US", "Narnia") == nil
      assert Geo.normalize_subdivision(nil, "New York") == nil
      assert Geo.normalize_subdivision("US", "") == nil
    end
  end

  describe "options" do
    test "a legacy country leads the list, a known code does not" do
      assert [{"Atlantis", "Atlantis"} | _] = Geo.country_options("Atlantis")
      assert {"Estonia", "EE"} = List.keyfind(Geo.country_options("EE"), "EE", 1)
      assert length(Geo.country_options(nil)) == length(Geo.country_options("EE"))
    end

    test "country labels start with the name, so typing in the select finds them" do
      labels = Enum.map(Geo.country_options(nil), &elem(&1, 0))

      assert Enum.all?(labels, &String.match?(&1, ~r/^[\p{L}\p{N}]/u))
      assert "Estonia" in labels
    end

    test "subdivision options come with the id as the value" do
      assert {"New York", "NY"} in Geo.subdivision_options("US", nil)
      assert [{"Old Place", "Old Place"} | _] = Geo.subdivision_options("US", "Old Place")
      assert Geo.subdivision_options(nil, nil) == []
    end

    test "city options are keyed by the English name" do
      options = Geo.city_options("EE", nil, nil)
      assert {"Tallinn", "Tallinn"} in options
      assert length(options) <= 11
    end

    test "a city the library added beyond the ten largest is offered" do
      assert {"Suwałki", "Suwałki"} in Geo.city_options("PL", nil, nil)
    end

    test "the US and Canada list cities per state or province" do
      ny = Geo.city_options("US", "NY", nil)
      assert {"New York", "New York"} in ny
      refute {"Los Angeles", "Los Angeles"} in ny

      # Without a state, the country-wide list.
      assert {"Los Angeles", "Los Angeles"} in Geo.city_options("US", nil, nil)
      assert {"Toronto", "Toronto"} in Geo.city_options("CA", "ON", nil)
    end

    test "a stored city outside the list stays selectable" do
      assert [{"Kärdla", "Kärdla"} | _] = Geo.city_options("EE", nil, "Kärdla")
    end

    test "cities? is false without a country or when the state has none" do
      refute Geo.cities?(nil, nil)
      refute Geo.cities?("US", "Narnia")
      assert Geo.cities?("EE", nil)
    end
  end

  describe "labels" do
    test "follow the country" do
      assert Geo.postal_code_label("US") == "ZIP Code"
      assert Geo.postal_code_label("EE") == "Postal Code"
      assert Geo.postal_code_label(nil) == "Postal Code"
      assert Geo.subdivision_label("US") == "State"
      assert Geo.subdivision_label("EE") == "Region"
      assert Geo.subdivision_label("CA") == "Province / Territory"
      assert Geo.subdivision_label(nil) == "State / Region"
    end
  end

  describe "country_name/1" do
    test "shows a code as its name and anything else as typed" do
      assert Geo.country_name("EE") == "Estonia"
      assert Geo.country_name("Atlantis") == "Atlantis"
      assert Geo.country_name("") == nil
      assert Geo.country_name(nil) == nil
    end
  end

  describe "country_aliases/1" do
    test "covers the code and the names a stored row may hold" do
      aliases = Geo.country_aliases("EE")
      assert "ee" in aliases
      assert "estonia" in aliases
      assert Geo.country_aliases("Atlantis") == ["atlantis"]
      assert Geo.country_aliases(nil) == []
    end
  end

  describe "legacy_fixes/1 and normalize_changeset/1" do
    test "converts only what changes" do
      assert Geo.legacy_fixes(%{country: "Estonia", state: "Harju"}) ==
               %{"country" => "EE", "state" => "37"}

      assert Geo.legacy_fixes(%{country: "EE", state: "37"}) == %{}
      assert Geo.legacy_fixes(%{country: "Atlantis", state: "x"}) == %{}
      assert Geo.legacy_fixes(%{country: nil, state: nil}) == %{}
    end

    test "the location changeset stores codes" do
      changeset =
        Location.changeset(%Location{}, %{
          name: "HQ",
          country: "United States",
          state: "New York"
        })

      assert Ecto.Changeset.get_field(changeset, :country) == "US"
      assert Ecto.Changeset.get_field(changeset, :state) == "NY"
    end

    test "text that matches nothing is kept" do
      changeset =
        Location.changeset(%Location{}, %{name: "HQ", country: "Atlantis", state: "Deep"})

      assert Ecto.Changeset.get_field(changeset, :country) == "Atlantis"
      assert Ecto.Changeset.get_field(changeset, :state) == "Deep"
    end
  end
end
