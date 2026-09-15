defmodule PhoenixKitLocations.MediaReorganizerTest do
  use PhoenixKitLocations.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitLocations.LiveCase
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.MediaReorganizer
  alias PhoenixKitLocations.Schemas.{Location, Space}
  alias PhoenixKitLocations.Spaces

  defmodule Hook do
    def parent(:location, _actor, %Location{}), do: {:ok, Process.get(:target_folder)}
    def parent(:space, _actor, %Space{}), do: {:ok, Process.get(:target_folder)}
    def parent(_, _, _), do: nil
    def name(_resource, _actor), do: {:ok, Process.get(:target_name) || nil}
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_locations, :attachments_parent_folder)
      Application.delete_env(:phoenix_kit_locations, :attachments_folder_name)
    end)

    :ok
  end

  defp new_location(attrs \\ %{}) do
    LiveCase.fixture_location(attrs)
  end

  defp new_space(location, attrs) do
    {:ok, space} =
      Spaces.create_space(
        Map.merge(
          %{name: "Floor", kind: "floor", location_uuid: location.uuid},
          attrs
        )
      )

    space
  end

  test "no hooks configured, legacy folder at root, pointer set → nothing planned" do
    location = new_location()

    {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

    {:ok, _location} =
      Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :location and &1.label == location.name))
  end

  test "hooks configured, legacy folder at root, pointer set → one move action" do
    location = new_location(%{name: "Tallinn HQ"})

    {:ok, target} = Storage.create_folder(%{name: "Locations"})
    {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

    {:ok, location} =
      Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location))

    assert action.source == "locations"
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == "Nice"
    assert action.on_conflict == :suffix
    assert action.counts == {0, 0}
    assert action.label == location.name
    # pointer already correct → no back-fill needed
    assert is_nil(action.after_move)
  end

  test "counts include a trashed file — the engine re-measures the same way at apply time" do
    user = LiveCase.fixture_user()
    location = new_location(%{name: "Tallinn HQ"})

    {:ok, target} = Storage.create_folder(%{name: "Locations"})
    {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

    {:ok, _location} =
      Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

    {:ok, _trashed_file} =
      Storage.create_file(%{
        original_file_name: "old.pdf",
        file_name: "old.pdf",
        mime_type: "application/pdf",
        file_type: "document",
        ext: "pdf",
        file_checksum: "checksum-trashed",
        user_file_checksum: "user-checksum-trashed",
        size: 10,
        status: "trashed",
        folder_uuid: folder.uuid,
        user_uuid: user.uuid
      })

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location))

    assert action.counts == {1, 0}
  end

  test "pointer missing (folder found by legacy name) → after_move back-fills it" do
    location = new_location(%{name: "Tallinn HQ"})

    {:ok, target} = Storage.create_folder(%{name: "Locations"})
    {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location))

    assert action.folder.uuid == folder.uuid
    assert is_function(action.after_move, 0)

    assert :ok = action.after_move.()

    reloaded = Locations.get_location(location.uuid)
    assert reloaded.data["files_folder_uuid"] == folder.uuid
  end

  test "after_move preserves other keys already in data (featured_image_uuid)" do
    location = new_location(%{name: "Tallinn HQ"})

    {:ok, location} =
      Locations.update_location(location, %{data: %{"featured_image_uuid" => "abc"}})

    {:ok, target} = Storage.create_folder(%{name: "Locations"})
    {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location))

    assert :ok = action.after_move.()

    reloaded = Locations.get_location(location.uuid)
    assert reloaded.data["files_folder_uuid"] == folder.uuid
    assert reloaded.data["featured_image_uuid"] == "abc"
  end

  test "pointer points at a trashed folder while a live legacy folder exists at root → the live one is used" do
    location = new_location()

    {:ok, trashed} = Storage.create_folder(%{name: "old-pointer-target"})
    {:ok, trashed} = Storage.trash_folder(trashed)
    {:ok, live} = Storage.create_folder(%{name: "location-#{location.uuid}"})

    {:ok, location} =
      Locations.update_location(location, %{data: %{"files_folder_uuid" => trashed.uuid}})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location and &1.label == location.name))

    refute is_nil(action)
    assert action.folder.uuid == live.uuid
  end

  test "folder already at the right parent/name but pointer missing → move action with after_move" do
    location = new_location(%{name: "Tallinn HQ"})

    {:ok, target} = Storage.create_folder(%{name: "Locations"})

    {:ok, folder} =
      Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location and &1.label == location.name))

    refute is_nil(action)
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
    assert action.name == folder.name
    assert is_function(action.after_move, 0)
  end

  test "folder already at the right parent/name and pointer already correct → nothing planned" do
    location = new_location(%{name: "Tallinn HQ"})

    {:ok, target} = Storage.create_folder(%{name: "Locations"})

    {:ok, folder} =
      Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

    {:ok, _location} =
      Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :location and &1.label == location.name))
  end

  test "spaces get actions too, keyed by the location-space- legacy prefix" do
    location = new_location()
    space = new_space(location, %{name: "Second Floor"})

    {:ok, target} = Storage.create_folder(%{name: "Spaces"})
    {:ok, folder} = Storage.create_folder(%{name: "location-space-#{space.uuid}"})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :space and &1.label == space.name))

    refute is_nil(action)
    assert action.op == :move
    assert action.folder.uuid == folder.uuid
    assert action.parent_uuid == target.uuid
  end

  test "space after_move back-fills its own data pointer without touching the location" do
    location = new_location()
    space = new_space(location, %{name: "Second Floor"})
    {:ok, folder} = Storage.create_folder(%{name: "location-space-#{space.uuid}"})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :space and &1.label == space.name))

    refute is_nil(action)
    assert :ok = action.after_move.()

    reloaded = Spaces.get_space(space.uuid)
    assert reloaded.data["files_folder_uuid"] == folder.uuid
  end

  describe "pending folders" do
    test "empty pending folder older than pending_days → op: :trash" do
      {:ok, folder} =
        Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :trash
    end

    test "non-empty pending folder → op: :report with the file name in the reason" do
      user = LiveCase.fixture_user()

      {:ok, folder} =
        Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _file} =
        Storage.create_file(%{
          original_file_name: "leftover.pdf",
          file_name: "leftover.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-1",
          user_file_checksum: "user-checksum-1",
          size: 10,
          status: "active",
          folder_uuid: folder.uuid,
          user_uuid: user.uuid
        })

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :report
      assert action.reason =~ "leftover.pdf"
    end

    test "pending folder younger than pending_days → no action" do
      {:ok, folder} =
        Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end
  end

  describe "orphan folders" do
    test "legacy folder with no matching record → orphan report with counts" do
      user = LiveCase.fixture_user()
      {:ok, folder} = Storage.create_folder(%{name: "location-#{Ecto.UUID.generate()}"})

      {:ok, _file} =
        Storage.create_file(%{
          original_file_name: "stray.pdf",
          file_name: "stray.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-orphan",
          user_file_checksum: "user-checksum-orphan",
          size: 5,
          status: "active",
          folder_uuid: folder.uuid,
          user_uuid: user.uuid
        })

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.source == "locations"
      assert action.op == :report
      assert action.counts == {1, 0}
      assert action.reason =~ "missing"
      assert action.reason =~ "1 file"
    end

    test "legacy space folder with no matching record → orphan report" do
      {:ok, folder} = Storage.create_folder(%{name: "location-space-#{Ecto.UUID.generate()}"})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))

      refute is_nil(action)
      assert action.reason =~ "missing"
    end

    test "legacy folder of a live location → not reported as orphan" do
      location = new_location()
      {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end

    test "legacy folder of an inactive (but not deleted) location → not reported as orphan" do
      location = new_location(%{status: "inactive"})
      {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      actions = MediaReorganizer.plan(nil, [])
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end
  end
end
