defmodule PhoenixKitLocationsTest do
  use ExUnit.Case

  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitLocations.Schemas.LocationType

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitLocations.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitLocations.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns locations" do
      assert PhoenixKitLocations.module_key() == "locations"
    end

    test "module_name/0 returns Locations" do
      assert PhoenixKitLocations.module_name() == "Locations"
    end

    test "enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitLocations.enabled?())
    end

    test "enable_system/0 is defined" do
      functions = PhoenixKitLocations.__info__(:functions)
      assert {:enable_system, 0} in functions
    end

    test "disable_system/0 is defined" do
      functions = PhoenixKitLocations.__info__(:functions)
      assert {:disable_system, 0} in functions
    end
  end

  describe "permission_metadata/0" do
    test "returns a map with required fields" do
      meta = PhoenixKitLocations.permission_metadata()
      assert %{key: key, label: label, icon: icon, description: desc} = meta
      assert is_binary(key)
      assert is_binary(label)
      assert is_binary(icon)
      assert is_binary(desc)
    end

    test "key matches module_key" do
      meta = PhoenixKitLocations.permission_metadata()
      assert meta.key == PhoenixKitLocations.module_key()
    end

    test "icon uses hero- prefix" do
      meta = PhoenixKitLocations.permission_metadata()
      assert String.starts_with?(meta.icon, "hero-")
    end
  end

  describe "admin_tabs/0" do
    test "returns a non-empty list of Tab structs" do
      tabs = PhoenixKitLocations.admin_tabs()
      assert [_ | _] = tabs
    end

    test "main tab has required fields" do
      [tab | _] = PhoenixKitLocations.admin_tabs()
      assert tab.id == :admin_locations
      assert tab.label == "Locations"
      assert is_binary(tab.path)
      assert tab.level == :admin
      assert tab.permission == PhoenixKitLocations.module_key()
      assert tab.group == :admin_modules
    end

    test "main tab has live_view for route generation" do
      [tab | _] = PhoenixKitLocations.admin_tabs()
      assert {PhoenixKitLocations.Web.LocationsLive, :index} = tab.live_view
    end

    test "all tabs have permission matching module_key" do
      for tab <- PhoenixKitLocations.admin_tabs() do
        assert tab.permission == PhoenixKitLocations.module_key()
      end
    end

    test "all subtabs reference parent" do
      [main | subtabs] = PhoenixKitLocations.admin_tabs()

      for tab <- subtabs do
        assert tab.parent == main.id
      end
    end

    test "visible subtabs include locations and types" do
      tabs = PhoenixKitLocations.admin_tabs()
      visible_ids = tabs |> Enum.filter(&(&1.visible != false)) |> Enum.map(& &1.id)
      assert :admin_locations_list in visible_ids
      assert :admin_locations_types in visible_ids
    end
  end

  describe "version/0" do
    test "returns version string" do
      assert PhoenixKitLocations.version() == "0.1.1"
    end
  end

  describe "optional callbacks" do
    test "get_config/0 returns a map" do
      config = PhoenixKitLocations.get_config()
      assert is_map(config)
      assert Map.has_key?(config, :enabled)
    end

    test "css_sources/0 returns otp app name as atom list" do
      assert PhoenixKitLocations.css_sources() == [:phoenix_kit_locations]
    end

    test "settings_tabs/0 returns empty list" do
      assert PhoenixKitLocations.settings_tabs() == []
    end

    test "user_dashboard_tabs/0 returns empty list" do
      assert PhoenixKitLocations.user_dashboard_tabs() == []
    end

    test "children/0 returns empty list" do
      assert PhoenixKitLocations.children() == []
    end

    test "route_module/0 returns nil" do
      assert PhoenixKitLocations.route_module() == nil
    end
  end

  describe "schemas" do
    test "Location changeset validates required name" do
      changeset =
        Location.changeset(
          %Location{},
          %{}
        )

      refute changeset.valid?
      assert changeset.errors[:name]
    end

    test "Location changeset validates email format" do
      changeset =
        Location.changeset(
          %Location{},
          %{name: "Test", email: "notanemail"}
        )

      refute changeset.valid?
      assert changeset.errors[:email]
    end

    test "Location changeset validates website format" do
      changeset =
        Location.changeset(
          %Location{},
          %{name: "Test", website: "notaurl"}
        )

      refute changeset.valid?
      assert changeset.errors[:website]
    end

    test "Location changeset accepts valid data" do
      changeset =
        Location.changeset(
          %Location{},
          %{name: "HQ", email: "hq@example.com", website: "https://example.com", status: "active"}
        )

      assert changeset.valid?
    end

    test "LocationType changeset validates required name" do
      changeset =
        LocationType.changeset(
          %LocationType{},
          %{}
        )

      refute changeset.valid?
      assert changeset.errors[:name]
    end

    test "LocationType changeset accepts valid data" do
      changeset =
        LocationType.changeset(
          %LocationType{},
          %{name: "Showroom", status: "active"}
        )

      assert changeset.valid?
    end

    test "Location changeset rejects invalid status" do
      changeset =
        Location.changeset(
          %Location{},
          %{name: "Test", status: "bogus"}
        )

      refute changeset.valid?
      assert changeset.errors[:status]
    end
  end
end
