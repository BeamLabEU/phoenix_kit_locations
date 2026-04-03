defmodule PhoenixKitLocationsTest do
  use ExUnit.Case

  describe "PhoenixKit.Module behaviour" do
    test "module_key/0 returns locations" do
      assert PhoenixKitLocations.module_key() == "locations"
    end

    test "module_name/0 returns Locations" do
      assert PhoenixKitLocations.module_name() == "Locations"
    end

    test "version/0 returns current version" do
      assert PhoenixKitLocations.version() == "0.1.0"
    end

    test "permission_metadata/0 key matches module_key" do
      meta = PhoenixKitLocations.permission_metadata()
      assert meta.key == PhoenixKitLocations.module_key()
    end

    test "admin_tabs/0 returns non-empty list" do
      tabs = PhoenixKitLocations.admin_tabs()
      assert is_list(tabs) and length(tabs) > 0
    end

    test "css_sources/0 returns otp app name" do
      assert PhoenixKitLocations.css_sources() == ["phoenix_kit_locations"]
    end
  end
end
