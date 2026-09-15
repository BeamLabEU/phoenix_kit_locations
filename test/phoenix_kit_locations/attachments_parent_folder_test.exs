defmodule PhoenixKitLocations.AttachmentsParentFolderTest do
  use PhoenixKitLocations.DataCase, async: false
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitLocations.Attachments
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.{Location, Space}

  defmodule Hook do
    def parent(:location, _a, %Location{}), do: {:ok, Process.get(:locations)}
    def parent(:space, _a, %Space{location_uuid: l}), do: {:ok, Process.get({:loc_folder, l})}
    def parent(_, _, _), do: nil
    def name(%Location{name: n}, _), do: {:ok, n}
    def name(%Space{name: n}, _), do: {:ok, n}
    def name(_, _), do: nil
  end

  # A per-actor container: no actor, no parent (as a per-user/tenant host would).
  defmodule ActorHook do
    def parent(_kind, nil, _resource), do: nil
    def parent(_kind, _actor, _resource), do: {:ok, Process.get(:locations)}
  end

  defmodule RaisingHook do
    def parent(_kind, _actor, _resource), do: raise("host lookup down")
    def name(_resource, _actor), do: raise("host lookup down")
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_locations, :attachments_parent_folder)
      Application.delete_env(:phoenix_kit_locations, :attachments_folder_name)
    end)

    {:ok, locations} =
      Storage.create_folder(%{name: "Locations-#{System.unique_integer([:positive])}"})

    Process.put(:locations, locations.uuid)
    %{locations: locations}
  end

  defp hooks_on do
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})
  end

  defp socket_for(resource) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    |> Attachments.mount(scope: "location", resource: resource)
  end

  defp owned_location(name, folder_uuid) do
    {:ok, location} =
      Locations.create_location(%{name: name, data: %{"files_folder_uuid" => folder_uuid}},
        owner_uuid: fixture_user().uuid
      )

    location
  end

  test "parent_folder_uuid receives the record; nil without config" do
    loc = %Location{uuid: Ecto.UUID.generate(), name: "Tallinn"}
    assert Attachments.parent_folder_uuid(loc, nil) == nil
    hooks_on()
    assert Attachments.parent_folder_uuid(loc, nil) == Process.get(:locations)
  end

  test "folder_name prefers the host name" do
    loc = %Location{uuid: Ecto.UUID.generate(), name: "Tallinn"}
    assert Attachments.folder_name(loc, nil) == "location-#{loc.uuid}"
    hooks_on()
    assert Attachments.folder_name(loc, nil) == "Tallinn"
  end

  test "find_resource_folder: host name under parent, deterministic under parent, deterministic at root",
       %{locations: l} do
    hooks_on()
    loc = %Location{uuid: Ecto.UUID.generate(), name: "Tallinn"}
    {:ok, at_root} = Storage.create_folder(%{name: "location-#{loc.uuid}"})
    assert Attachments.find_resource_folder(loc, nil).uuid == at_root.uuid
    {:ok, det} = Storage.create_folder(%{name: "location-#{loc.uuid}", parent_uuid: l.uuid})
    assert Attachments.find_resource_folder(loc, nil).uuid == det.uuid
    {:ok, named} = Storage.create_folder(%{name: "Tallinn", parent_uuid: l.uuid})
    assert Attachments.find_resource_folder(loc, nil).uuid == named.uuid
  end

  test "an unsaved location never adopts a same-named folder", %{locations: l} do
    hooks_on()
    {:ok, _} = Storage.create_folder(%{name: "Draft", parent_uuid: l.uuid})
    assert Attachments.find_resource_folder(%Location{name: "Draft"}, nil) == nil
  end

  describe "same-named locations of different owners" do
    test "a host-named folder another location points at is not adopted", %{locations: l} do
      hooks_on()
      {:ok, theirs} = Storage.create_folder(%{name: "Warehouse", parent_uuid: l.uuid})
      their_location = owned_location("Warehouse", theirs.uuid)
      mine = owned_location("Warehouse", nil)

      assert Attachments.find_resource_folder(mine, nil) == nil
      assert Attachments.find_resource_folder(their_location, nil).uuid == theirs.uuid
    end

    test "opening the picker creates this location's own folder, never theirs",
         %{locations: l} do
      hooks_on()
      {:ok, theirs} = Storage.create_folder(%{name: "Warehouse", parent_uuid: l.uuid})
      _their_location = owned_location("Warehouse", theirs.uuid)
      mine = owned_location("Warehouse", nil)

      {:noreply, socket} =
        Attachments.open_featured_image_picker(socket_for(mine), "location")

      folder_uuid = Attachments.state(socket, "location").folder_uuid
      assert folder_uuid != theirs.uuid

      folder = Repo.get!(Folder, folder_uuid)
      assert folder.name == "location-#{mine.uuid}"
      assert folder.parent_uuid == l.uuid
    end

    test "the pending rename falls back to the deterministic name when the host name is taken",
         %{locations: l} do
      hooks_on()
      {:ok, _theirs} = Storage.create_folder(%{name: "Tartu", parent_uuid: l.uuid})

      {:ok, pending} =
        Storage.create_folder(%{
          name: "location-attachment-pending-#{Ecto.UUID.generate()}",
          parent_uuid: l.uuid
        })

      loc = %Location{uuid: Ecto.UUID.generate(), name: "Tartu"}
      assert :ok = Attachments.maybe_rename_pending_folder_for(pending.uuid, loc)

      f = Repo.get!(Folder, pending.uuid)
      assert f.name == "location-#{loc.uuid}"
      assert f.parent_uuid == l.uuid
    end
  end

  test "pending rename takes the host name and keeps the parent", %{locations: l} do
    hooks_on()

    {:ok, pending} =
      Storage.create_folder(%{
        name: "location-attachment-pending-#{Ecto.UUID.generate()}",
        parent_uuid: l.uuid
      })

    loc = %Location{uuid: Ecto.UUID.generate(), name: "Tartu"}
    assert :ok = Attachments.maybe_rename_pending_folder_for(pending.uuid, loc)
    f = Repo.get!(Folder, pending.uuid)
    assert f.name == "Tartu"
    assert f.parent_uuid == l.uuid
  end

  test "pending rename never moves the folder, even when the hook needs an actor",
       %{locations: l} do
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {ActorHook, :parent})

    {:ok, pending} =
      Storage.create_folder(%{
        name: "location-attachment-pending-#{Ecto.UUID.generate()}",
        parent_uuid: l.uuid
      })

    loc = %Location{uuid: Ecto.UUID.generate(), name: "Tartu"}
    assert :ok = Attachments.maybe_rename_pending_folder_for(pending.uuid, loc)

    f = Repo.get!(Folder, pending.uuid)
    assert f.name == "location-#{loc.uuid}"
    assert f.parent_uuid == l.uuid
  end

  test "pending rename leaves a folder that is not pending alone", %{locations: l} do
    hooks_on()
    {:ok, folder} = Storage.create_folder(%{name: "Kept", parent_uuid: l.uuid})
    loc = %Location{uuid: Ecto.UUID.generate(), name: "Tartu"}

    assert :ok = Attachments.maybe_rename_pending_folder_for(folder.uuid, loc)
    assert Repo.get!(Folder, folder.uuid).name == "Kept"
  end

  test "raising hooks degrade to the root and the deterministic name" do
    Application.put_env(
      :phoenix_kit_locations,
      :attachments_parent_folder,
      {RaisingHook, :parent}
    )

    Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {RaisingHook, :name})
    loc = %Location{uuid: Ecto.UUID.generate(), name: "Tallinn"}

    ExUnit.CaptureLog.capture_log(fn ->
      assert Attachments.parent_folder_uuid(loc, nil) == nil
      assert Attachments.folder_name(loc, nil) == "location-#{loc.uuid}"
    end)
  end
end
