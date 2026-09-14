defmodule PhoenixKitLocations.AttachmentsParentFolderTest do
  use PhoenixKitLocations.DataCase, async: false
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitLocations.Attachments
  alias PhoenixKitLocations.Schemas.{Location, Space}

  defmodule Hook do
    def parent(:location, _a, %Location{}), do: {:ok, Process.get(:locations)}
    def parent(:space, _a, %Space{location_uuid: l}), do: {:ok, Process.get({:loc_folder, l})}
    def parent(_, _, _), do: nil
    def name(%Location{name: n}, _), do: {:ok, n}
    def name(%Space{name: n}, _), do: {:ok, n}
    def name(_, _), do: nil
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

  test "pending rename keeps the parent", %{locations: l} do
    hooks_on()

    {:ok, pending} =
      Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

    loc = %Location{uuid: Ecto.UUID.generate(), name: "Tartu"}
    assert :ok = Attachments.maybe_rename_pending_folder_for(pending.uuid, loc)
    f = Repo.get!(Folder, pending.uuid)
    assert f.name == "Tartu"
    assert f.parent_uuid == l.uuid
  end
end
