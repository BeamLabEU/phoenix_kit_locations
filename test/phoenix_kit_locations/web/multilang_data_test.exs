defmodule PhoenixKitLocations.Web.MultilangDataTest do
  @moduledoc """
  A location's and a space's `data` holds two things side by side: the
  translations core's `MultilangForm` writes (`"_primary_language"` plus one
  map per language) and the attachment pointers this module writes
  (`files_folder_uuid`, `featured_image_uuid`, top-level). Every save must
  keep both, whichever language tab is saved, whether multilingual content
  is on or off, and whichever path changes a name
  (`PhoenixKitLocations.TranslatedData`).
  """
  use PhoenixKitLocations.LiveCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Storage
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.Space
  alias PhoenixKitLocations.Spaces
  alias PhoenixKitLocations.Test.Repo

  @pointer_keys ~w(files_folder_uuid featured_image_uuid)

  setup %{conn: conn} do
    user = fixture_user()
    n = System.unique_integer([:positive])
    {:ok, folder} = Storage.create_folder(%{name: "multilang-#{n}"})

    {:ok, image} =
      Storage.create_file(%{
        original_file_name: "front.jpg",
        file_name: "front.jpg",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: "c-#{n}",
        user_file_checksum: "u-#{n}",
        size: 10,
        status: "active",
        user_uuid: user.uuid,
        folder_uuid: folder.uuid
      })

    pointers = %{"files_folder_uuid" => folder.uuid, "featured_image_uuid" => image.uuid}
    %{conn: put_test_scope(conn, fake_scope(user_uuid: user.uuid)), pointers: pointers}
  end

  defp enable_french do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("fr-FR")
  end

  # Core debounces the tab switch (`Process.send_after/3`); apply it now.
  defp switch_lang(view, lang) do
    render_click(view, "switch_language", %{"lang" => lang})
    send(view.pid, {:__multilang_apply_lang__, lang})
    render(view)
  end

  # Written straight to the row, as an earlier release or another writer
  # left it, bypassing the changeset under test.
  defp put_data(record, data) do
    record |> Ecto.Changeset.change(data: data) |> Repo.update!()
  end

  defp translated(main_name, french_name) do
    %{
      "_primary_language" => "en-US",
      "en-US" => %{"_name" => main_name},
      "fr-FR" => %{"_name" => french_name}
    }
  end

  defp new_space(location, name) do
    {:ok, space} =
      Spaces.create_space(%{"location_uuid" => location.uuid, "kind" => "floor", "name" => name})

    space
  end

  defp refute_pointers_in_languages(data) do
    for {lang, %{} = entry} <- data, key <- @pointer_keys do
      refute Map.has_key?(entry, key),
             "#{key} was copied into the #{lang} entry: #{inspect(data)}"
    end
  end

  describe "location form, multilingual content on" do
    setup do
      enable_french()
      :ok
    end

    test "the first translation of a location with files keeps the pointers top-level only",
         ctx do
      location = put_data(fixture_location(%{name: "Head Office"}), ctx.pointers)

      {:ok, view, _html} = live(ctx.conn, "/admin/locations/#{location.uuid}/edit")
      switch_lang(view, "fr-FR")

      view
      |> form("#location-form", location: %{lang_name: "Siège"})
      |> render_submit()

      saved = Repo.reload(location)
      assert saved.name == "Head Office"
      assert get_in(saved.data, ["fr-FR", "_name"]) == "Siège"
      assert get_in(saved.data, ["en-US", "_name"]) == "Head Office"
      assert Map.take(saved.data, @pointer_keys) == ctx.pointers
      refute_pointers_in_languages(saved.data)
    end

    test "a main-language save keeps the translations and the pointers", ctx do
      location =
        put_data(
          fixture_location(%{name: "Head Office"}),
          Map.merge(translated("Head Office", "Siège"), ctx.pointers)
        )

      {:ok, view, _html} = live(ctx.conn, "/admin/locations/#{location.uuid}/edit")
      switch_lang(view, "en-US")

      view
      |> form("#location-form", location: %{name: "Main Office"})
      |> render_submit()

      saved = Repo.reload(location)
      assert saved.name == "Main Office"
      assert get_in(saved.data, ["en-US", "_name"]) == "Main Office"
      assert get_in(saved.data, ["fr-FR", "_name"]) == "Siège"
      assert Map.take(saved.data, @pointer_keys) == ctx.pointers
      refute_pointers_in_languages(saved.data)
    end
  end

  describe "multilingual content off" do
    test "a location save keeps the translations and follows the new name", ctx do
      location =
        put_data(
          fixture_location(%{name: "Head Office"}),
          Map.merge(translated("Head Office", "Siège"), ctx.pointers)
        )

      {:ok, view, _html} = live(ctx.conn, "/admin/locations/#{location.uuid}/edit")

      view
      |> form("#location-form", location: %{name: "Main Office"})
      |> render_submit()

      saved = Repo.reload(location)
      assert saved.name == "Main Office"
      assert get_in(saved.data, ["en-US", "_name"]) == "Main Office"
      assert get_in(saved.data, ["fr-FR", "_name"]) == "Siège"
      assert Map.take(saved.data, @pointer_keys) == ctx.pointers
    end

    test "a space save keeps the translations and follows the new name", ctx do
      location = fixture_location()

      space =
        location
        |> new_space("Ground")
        |> put_data(Map.merge(translated("Ground", "Rez-de-chaussée"), ctx.pointers))

      {:ok, view, _html} = live(ctx.conn, "/admin/locations/#{location.uuid}/structure")
      render_click(view, "select_space", %{"uuid" => space.uuid})

      view
      |> form("#space-detail-form", space: %{name: "Ground floor"})
      |> render_submit()

      saved = Repo.get!(Space, space.uuid)
      assert saved.name == "Ground floor"
      assert get_in(saved.data, ["en-US", "_name"]) == "Ground floor"
      assert get_in(saved.data, ["fr-FR", "_name"]) == "Rez-de-chaussée"
      assert Map.take(saved.data, @pointer_keys) == ctx.pointers
    end

    test "a location type save keeps the translations and follows the new name", ctx do
      type =
        put_data(fixture_location_type(%{name: "Warehouse"}), translated("Warehouse", "Entrepôt"))

      {:ok, view, _html} = live(ctx.conn, "/admin/locations/types/#{type.uuid}/edit")

      view
      |> form("#location-type-form", location_type: %{name: "Depot"})
      |> render_submit()

      saved = Repo.reload(type)
      assert saved.name == "Depot"
      assert get_in(saved.data, ["en-US", "_name"]) == "Depot"
      assert get_in(saved.data, ["fr-FR", "_name"]) == "Entrepôt"
    end
  end

  describe "an owner without locations.manage_all, multilingual content off" do
    setup ctx do
      owner = fixture_user()

      conn =
        Phoenix.ConnTest.build_conn()
        |> put_test_scope(fake_scope(user_uuid: owner.uuid, permissions: ["locations"]))

      {:ok, location} = Locations.create_location(%{name: "Shop"}, owner_uuid: owner.uuid)
      %{ctx | conn: conn} |> Map.put(:location, location)
    end

    # The Files card is hidden from them, not unmounted: a save writes back
    # the pointers an admin set.
    test "a save keeps the files and translations an admin set", ctx do
      location = put_data(ctx.location, Map.merge(translated("Shop", "Boutique"), ctx.pointers))

      {:ok, view, _html} = live(ctx.conn, "/admin/locations/#{location.uuid}/edit")

      view
      |> form("#location-form", location: %{name: "Corner Shop"})
      |> render_submit()

      saved = Repo.reload(location)
      assert saved.name == "Corner Shop"
      assert get_in(saved.data, ["fr-FR", "_name"]) == "Boutique"
      assert Map.take(saved.data, @pointer_keys) == ctx.pointers
    end

    test "a client-sent data map is ignored", ctx do
      {:ok, view, _html} = live(ctx.conn, "/admin/locations/#{ctx.location.uuid}/edit")

      render_submit(view, "save", %{
        "location" => %{"name" => "Shop", "data" => %{"fr-FR" => %{"_name" => "Forged"}}}
      })

      assert Repo.reload(ctx.location).data == %{}
    end
  end

  describe "the main-language entry follows the columns on every path" do
    setup do
      enable_french()
      :ok
    end

    test "a rename in the space tree", ctx do
      location = fixture_location(%{name: "Head Office"})
      space = location |> new_space("Ground") |> put_data(translated("Ground", "Rez-de-chaussée"))

      {:ok, view, _html} = live(ctx.conn, "/admin/locations/#{location.uuid}/structure")
      render_click(view, "rename_space", %{"uuid" => space.uuid, "name" => "Lobby"})

      saved = Repo.get!(Space, space.uuid)
      assert saved.name == "Lobby"
      assert get_in(saved.data, ["en-US", "_name"]) == "Lobby"
      assert get_in(saved.data, ["fr-FR", "_name"]) == "Rez-de-chaussée"
      assert Spaces.full_path(space.uuid, locale: "en-US") == "Head Office / Lobby"
    end

    test "a host's update_location/3, and a cleared description", ctx do
      location =
        put_data(
          fixture_location(%{name: "Head Office", description: "Old"}),
          Map.merge(translated("Head Office", "Siège"), ctx.pointers)
          |> put_in(["en-US", "_description"], "Old")
        )

      space = new_space(location, "Ground")

      {:ok, saved} = Locations.update_location(location, %{name: "Main Office", description: ""})

      assert get_in(saved.data, ["en-US", "_name"]) == "Main Office"
      refute Map.has_key?(saved.data["en-US"], "_description")
      assert get_in(saved.data, ["fr-FR", "_name"]) == "Siège"
      assert Map.take(saved.data, @pointer_keys) == ctx.pointers
      assert Spaces.full_path(space.uuid, locale: "en-US") == "Main Office / Ground"
      assert Spaces.full_path(space.uuid, locale: "fr-FR") == "Siège / Ground"
    end

    # Keeping the main entry in step writes `data` on a rename that names
    # none, so it must start from the locked row, not from a copy loaded
    # before another session claimed a folder or saved a translation.
    test "a rename through a stale struct keeps what was written since", ctx do
      %{"files_folder_uuid" => folder} = ctx.pointers

      location =
        put_data(fixture_location(%{name: "Head Office"}), translated("Head Office", "Siège"))

      space = location |> new_space("Ground") |> put_data(translated("Ground", "Rez-de-chaussée"))

      since = fn data ->
        data |> Map.put("files_folder_uuid", folder) |> put_in(["fr-FR", "_name"], "Nouveau")
      end

      put_data(location, since.(location.data))
      put_data(space, since.(space.data))

      {:ok, saved_location} = Locations.update_location(location, %{name: "Main Office"})
      {:ok, saved_space} = Spaces.update_space(space, %{"name" => "Lobby"})

      for {saved, main} <- [{saved_location, "Main Office"}, {saved_space, "Lobby"}] do
        assert saved.data["files_folder_uuid"] == folder
        assert get_in(saved.data, ["fr-FR", "_name"]) == "Nouveau"
        assert get_in(saved.data, ["en-US", "_name"]) == main
      end
    end

    test "pointer copies left in a language entry go, and a removed image stays removed", ctx do
      %{"files_folder_uuid" => folder} = ctx.pointers

      # As an earlier release left it: copies in the main entry, the featured
      # image removed since (gone top-level, still in the copy).
      location =
        put_data(fixture_location(%{name: "Head Office"}), %{
          "_primary_language" => "en-US",
          "en-US" => Map.merge(%{"_name" => "Head Office"}, ctx.pointers),
          "files_folder_uuid" => folder
        })

      {:ok, saved} = Locations.update_location(location, %{status: "inactive"})

      assert saved.data["files_folder_uuid"] == folder
      refute Map.has_key?(saved.data, "featured_image_uuid")
      refute_pointers_in_languages(saved.data)
    end
  end
end
