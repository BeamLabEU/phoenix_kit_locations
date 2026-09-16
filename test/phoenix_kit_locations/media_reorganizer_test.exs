defmodule PhoenixKitLocations.MediaReorganizerTest do
  use PhoenixKitLocations.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FolderLink
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

  defmodule RaisingHook do
    def parent(:location, _actor, %Location{}), do: raise("boom")
    def parent(:space, _actor, %Space{}), do: raise("boom")
    def parent(_, _, _), do: nil
  end

  defmodule ErrorHook do
    def parent(:location, _actor, %Location{}), do: {:error, :timeout}
    def parent(_, _, _), do: nil
  end

  defmodule RaisingNameHook do
    def name(_resource, _actor), do: raise("boom")
  end

  # R9: a host hook is opaque — it may read any column off the resource,
  # not just the light-select set (uuid/name/status/pointer). These two
  # hooks only resolve a target when a column OUTSIDE that light set is
  # actually populated, proving the plan hands the hook the FULL row.
  defmodule LocationCityHook do
    def parent(:location, _actor, %Location{city: city}) when is_binary(city) do
      {:ok, Process.get(:target_folder)}
    end

    def parent(:location, _actor, %Location{}) do
      raise "missing struct key: city not loaded on the record handed to the hook"
    end

    def parent(_, _, _), do: nil
  end

  # T11: `location_uuid` is already part of the light `Space` select, so a
  # hook keyed on it could pass even without the full-row hydration fix —
  # this test cannot fail on a regression. `description` is NOT selected
  # by `light_spaces/0`, so only the FULL row carries it.
  defmodule SpaceDescriptionHook do
    def parent(:space, _actor, %Space{description: description})
        when is_binary(description) do
      {:ok, Process.get(:target_folder)}
    end

    def parent(:space, _actor, %Space{}), do: nil
    def parent(_, _, _), do: nil
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

  test "no hooks configured, legacy folder at root, pointer missing → not even a back-fill is planned" do
    location = new_location()

    {:ok, _folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

    # D1: a host without a configured parent hook is untouched — no move,
    # no pointer back-fill either, even though one would otherwise apply.
    actions = MediaReorganizer.plan(nil, [])
    refute Enum.any?(actions, &(&1.kind == :location and &1.label == location.name))
  end

  test "hooks configured, pointer folder still has the legacy name → gets renamed (E2)" do
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
    # E2: the pointer folder still literally reads the legacy name, so it
    # gets the host name like any other candidate.
    assert action.name == "Nice"
    assert action.on_conflict == :suffix
    assert action.counts == {0, 0}
    assert action.label == location.name
    # pointer already correct → no back-fill needed
    assert is_nil(action.after_move)
  end

  test "hooks configured, pointer folder already renamed by the owner → kept as-is (D6)" do
    location = new_location(%{name: "Tallinn HQ"})

    {:ok, target} = Storage.create_folder(%{name: "Locations"})

    {:ok, folder} =
      Storage.create_folder(%{name: "Owner renamed this", parent_uuid: target.uuid})

    {:ok, _location} =
      Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])

    # Already at the right parent and the pointer is correct — the name
    # hook is never called (R8) and nothing is planned.
    refute Enum.any?(actions, &(&1.kind == :location and &1.label == location.name))
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

  test "after_move re-reads fresh data before merging — a concurrent edit made after plan/2 is not reverted" do
    location = new_location(%{name: "Tallinn HQ"})

    {:ok, target} = Storage.create_folder(%{name: "Locations"})
    {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location))
    assert is_function(action.after_move, 0)

    # Simulate another editor changing an unrelated `data` key after plan/2
    # captured this location's struct but before this run's after_move
    # fires — the back-fill must not revert it.
    {:ok, _location} =
      Locations.update_location(location, %{data: %{"featured_image_uuid" => "concurrent"}})

    assert :ok = action.after_move.()

    reloaded = Locations.get_location(location.uuid)
    assert reloaded.data["files_folder_uuid"] == folder.uuid
    assert reloaded.data["featured_image_uuid"] == "concurrent"
  end

  test "pointer points at a trashed folder while a live legacy folder exists at root → the live one is used" do
    location = new_location()

    {:ok, trashed} = Storage.create_folder(%{name: "old-pointer-target"})
    {:ok, trashed} = Storage.trash_folder(trashed)
    {:ok, live} = Storage.create_folder(%{name: "location-#{location.uuid}"})

    {:ok, location} =
      Locations.update_location(location, %{data: %{"files_folder_uuid" => trashed.uuid}})

    # D1: a hook must be configured (even one that resolves to root) for
    # the Source to plan anything at all.
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location and &1.label == location.name))

    refute is_nil(action)
    assert action.folder.uuid == live.uuid
  end

  test "trashed folder sharing the legacy name at root does not hide the live folder under the resolved parent" do
    location = new_location()

    {:ok, target} = Storage.create_folder(%{name: "Locations"})

    {:ok, trashed_at_root} = Storage.create_folder(%{name: "location-#{location.uuid}"})
    {:ok, _trashed_at_root} = Storage.trash_folder(trashed_at_root)

    {:ok, live} =
      Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location and &1.label == location.name))

    refute Enum.any?(actions, &(&1.kind == :duplicate))
    refute is_nil(action)
    assert action.folder.uuid == live.uuid
  end

  test "invalid pointer values ('' and 'abc') are treated as absent, never raise" do
    location1 = new_location(%{name: "First", data: %{"files_folder_uuid" => "abc"}})
    location2 = new_location(%{name: "Second", data: %{"files_folder_uuid" => ""}})

    {:ok, folder1} = Storage.create_folder(%{name: "location-#{location1.uuid}"})
    {:ok, folder2} = Storage.create_folder(%{name: "location-#{location2.uuid}"})

    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])

    action1 = Enum.find(actions, &(&1.kind == :location and &1.label == location1.name))
    action2 = Enum.find(actions, &(&1.kind == :location and &1.label == location2.name))

    refute is_nil(action1)
    refute is_nil(action2)
    assert action1.folder.uuid == folder1.uuid
    assert action2.folder.uuid == folder2.uuid
  end

  describe "duplicate folders (X5/X11)" do
    test "legacy folder live at both root and under the resolved parent → one duplicate report, no move" do
      location = new_location()

      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, at_root} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      {:ok, _under_parent} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == location.name))
      refute is_nil(dup)
      assert dup.op == :report
      assert dup.reason =~ at_root.uuid
    end

    test "two records whose current folder resolves to the same live folder → one duplicate report, no move" do
      location1 = new_location(%{name: "First"})
      location2 = new_location(%{name: "Second"})

      {:ok, shared} = Storage.create_folder(%{name: "shared-folder"})

      {:ok, location1} =
        Locations.update_location(location1, %{data: %{"files_folder_uuid" => shared.uuid}})

      {:ok, location2} =
        Locations.update_location(location2, %{data: %{"files_folder_uuid" => shared.uuid}})

      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == shared.name))
      refute is_nil(dup)
      assert dup.op == :report
      assert dup.reason =~ location1.name
      assert dup.reason =~ location2.name
    end
  end

  test "after_move writes the pointer with a direct repo update — no Activity log, no context call (X10/D7)" do
    location = new_location(%{name: "Tallinn HQ"})

    {:ok, target} = Storage.create_folder(%{name: "Locations"})

    {:ok, folder} =
      Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

    Process.put(:target_folder, target.uuid)
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location and &1.label == location.name))

    refute is_nil(action)
    assert :ok = action.after_move.()

    reloaded = Locations.get_location(location.uuid)
    assert reloaded.data["files_folder_uuid"] == folder.uuid
    refute_activity_logged("location.updated", resource_uuid: location.uuid)
  end

  test "host name taken by a folder another live record's pointer already claims falls back to the legacy name (D3)" do
    location1 = new_location(%{name: "Claimed"})
    location2 = new_location(%{name: "Other"})

    {:ok, target} = Storage.create_folder(%{name: "Locations"})

    {:ok, claimed_folder} =
      Storage.create_folder(%{name: "Nice", parent_uuid: target.uuid})

    {:ok, _location1} =
      Locations.update_location(location1, %{data: %{"files_folder_uuid" => claimed_folder.uuid}})

    {:ok, legacy_folder} = Storage.create_folder(%{name: "location-#{location2.uuid}"})

    Process.put(:target_folder, target.uuid)
    Process.put(:target_name, "Nice")
    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
    Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :location and &1.label == location2.name))

    refute is_nil(action)
    assert action.folder.uuid == legacy_folder.uuid
    # "Nice" is already claimed by location1's live pointer — falls back
    # to the deterministic legacy name instead of colliding with it.
    assert action.name == "location-#{location2.uuid}"
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

    Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

    actions = MediaReorganizer.plan(nil, [])
    action = Enum.find(actions, &(&1.kind == :space and &1.label == space.name))

    refute is_nil(action)
    assert :ok = action.after_move.()

    reloaded = Spaces.get_space(space.uuid)
    assert reloaded.data["files_folder_uuid"] == folder.uuid
  end

  describe "pending folders" do
    test "empty pending folder older than pending_days, hook configured → op: :trash" do
      {:ok, folder} =
        Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :trash
    end

    test "empty pending folder older than pending_days, no hook configured → op: :report (E1)" do
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

      assert action.op == :report
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

    test "pending folder holding only a trashed file → counted, reason says N trashed file(s), never empty (R6)" do
      user = LiveCase.fixture_user()

      {:ok, folder} =
        Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _file} =
        Storage.create_file(%{
          original_file_name: "trashed.pdf",
          file_name: "trashed.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-trashed-pending",
          user_file_checksum: "user-checksum-trashed-pending",
          size: 10,
          status: "trashed",
          folder_uuid: folder.uuid,
          user_uuid: user.uuid
        })

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :report
      assert action.counts == {1, 0}
      refute action.reason =~ "trashed.pdf"
      assert action.reason =~ "1 trashed file"
    end

    test "pending folder holding only a FolderLink-linked file → named in the reason" do
      user = LiveCase.fixture_user()
      {:ok, home_folder} = Storage.create_folder(%{name: "elsewhere"})

      {:ok, folder} =
        Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, file} =
        Storage.create_file(%{
          original_file_name: "linked.pdf",
          file_name: "linked.pdf",
          mime_type: "application/pdf",
          file_type: "document",
          ext: "pdf",
          file_checksum: "checksum-linked-pending",
          user_file_checksum: "user-checksum-linked-pending",
          size: 10,
          status: "active",
          folder_uuid: home_folder.uuid,
          user_uuid: user.uuid
        })

      {:ok, _link} =
        %FolderLink{}
        |> FolderLink.changeset(%{folder_uuid: folder.uuid, file_uuid: file.uuid})
        |> Repo.insert()

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      action = Enum.find(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))

      assert action.op == :report
      assert action.counts == {0, 1}
      assert action.reason =~ "linked.pdf"
    end

    test "pending folder younger than pending_days → no action" do
      {:ok, folder} =
        Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end

    test "pending folder a live record currently points at is never independently reported/trashed, hook configured too (X4)" do
      location = new_location()

      {:ok, folder} =
        Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

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

  describe "claims are hook-independent (R1)" do
    test "pending folder a live record's pointer names is never trashed, even with no hook configured" do
      location = new_location()

      {:ok, folder} =
        Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      # No hook configured at all — D1 leaves resource_plan empty, but R1
      # claims still come from the record's live pointer directly.
      actions = MediaReorganizer.plan(nil, pending_days: 7)

      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end
  end

  describe "hook failure (R2)" do
    test "hook raises → record skipped, one hook_error report with the count, never planned as root" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})

      {:ok, folder} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

      Application.put_env(
        :phoenix_kit_locations,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.op == :report
      assert error.reason =~ "1 record"
    end

    test "hook returns {:error, _} → same as raising, never treated as root" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

      Application.put_env(
        :phoenix_kit_locations,
        :attachments_parent_folder,
        {ErrorHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "hook raises for a space → space skipped, hook_error report, never planned as root" do
      location = new_location(%{name: "Tallinn HQ"})
      space = new_space(location, %{name: "1st floor"})

      {:ok, folder} = Storage.create_folder(%{name: "location-space-#{space.uuid}"})

      {:ok, _space} =
        Spaces.update_space(space, %{"data" => %{"files_folder_uuid" => folder.uuid}})

      Application.put_env(
        :phoenix_kit_locations,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :space))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.op == :report
      assert error.reason =~ "1 record"
    end
  end

  describe "host-named folder under parent (R3)" do
    test "unclaimed host-named folder under the resolved parent is the current folder → noop move, back-fill only" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, host_folder} = Storage.create_folder(%{name: "Nice", parent_uuid: target.uuid})

      # The legacy folder lives under a THIRD, unrelated parent (not root,
      # not the resolved parent) — that's what makes the record a
      # candidate at all; it is unreachable by the module's own lookup
      # order, so the host-named folder under the resolved parent is
      # unambiguously the current folder.
      {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else entirely"})

      {:ok, legacy} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: elsewhere.uuid})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Nice")
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :location and &1.label == location.name))

      refute is_nil(action)
      assert action.folder.uuid == host_folder.uuid
      assert action.parent_uuid == target.uuid
      assert is_function(action.after_move, 0)
      refute Enum.any?(actions, &(&1.kind == :duplicate))

      # The stray legacy twin under the third-party parent is never
      # adopted, but it must not go unreported either.
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.label == location.name))
      refute is_nil(relocated)
      assert relocated.folder.uuid == legacy.uuid
    end

    test "host-named folder AND a live legacy folder both under the resolved parent → duplicate, no move" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, _host_folder} = Storage.create_folder(%{name: "Nice", parent_uuid: target.uuid})

      {:ok, _legacy} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Nice")
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == location.name))
      refute is_nil(dup)
    end
  end

  describe "orphans exclude claimed folders (R4)" do
    test "a legacy-named folder claimed by a different live record's pointer is never also reported as an orphan" do
      other = new_location()
      # A folder named after a location uuid that does NOT exist — an
      # orphan candidate by name — but its pointer is actually claimed by
      # a different, live location. One folder gets at most one action.
      missing_uuid = Ecto.UUID.generate()
      {:ok, folder} = Storage.create_folder(%{name: "location-#{missing_uuid}"})

      {:ok, _other} =
        Locations.update_location(other, %{data: %{"files_folder_uuid" => folder.uuid}})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == folder.uuid))
    end
  end

  describe "orphan scope includes parents resolved only by a relocated candidate (U4)" do
    test "a parent no candidate ADOPTED, but the hook still resolved for a relocated one, is still scanned for orphans" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else entirely"})

      # This candidate never adopts `target` as its current folder — its
      # legacy folder lives under a third, unrelated parent, so it is
      # reported `:relocated`, not moved. The hook still ANSWERED
      # `target.uuid` for it though.
      {:ok, _legacy} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: elsewhere.uuid})

      # An orphaned legacy folder living under that same resolved parent —
      # only found if `target.uuid` stays in the orphan scan scope.
      missing_uuid = Ecto.UUID.generate()

      {:ok, orphan_folder} =
        Storage.create_folder(%{name: "location-#{missing_uuid}", parent_uuid: target.uuid})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.label == location.name))
      refute is_nil(relocated)

      orphan = Enum.find(actions, &(&1.kind == :orphan and &1.folder.uuid == orphan_folder.uuid))
      refute is_nil(orphan)
    end
  end

  describe "pointer normalisation (R5)" do
    test "an upper-case pointer still resolves to its (lower-case) live folder" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, folder} = Storage.create_folder(%{name: "Somewhere"})
      upcased = String.upcase(folder.uuid)

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => upcased}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])
      action = Enum.find(actions, &(&1.kind == :location and &1.label == location.name))

      refute is_nil(action)
      assert action.folder.uuid == folder.uuid
      assert action.parent_uuid == target.uuid
      # pointer already matches (after normalisation) → no back-fill needed
      assert is_nil(action.after_move)
    end

    test "an upper-case pointer to a pending folder claims it — never trashed" do
      location = new_location()

      {:ok, folder} =
        Storage.create_folder(%{name: "location-attachment-pending-#{Ecto.UUID.generate()}"})

      upcased = String.upcase(folder.uuid)

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => upcased}})

      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(f in Storage.Folder, where: f.uuid == ^folder.uuid),
        set: [inserted_at: old_time]
      )

      actions = MediaReorganizer.plan(nil, pending_days: 7)
      refute Enum.any?(actions, &(&1.kind == :pending and &1.folder.uuid == folder.uuid))
    end
  end

  describe "converging targets (R7/E3)" do
    test "two records with different current folders that would both move to the same destination → duplicate, no moves" do
      location1 = new_location(%{name: "First"})
      location2 = new_location(%{name: "Second"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, _folder1} = Storage.create_folder(%{name: "location-#{location1.uuid}"})
      {:ok, _folder2} = Storage.create_folder(%{name: "location-#{location2.uuid}"})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Same name")
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))

      dup =
        Enum.find(
          actions,
          &(&1.kind == :duplicate and &1.label =~ "First" and &1.label =~ "Second")
        )

      refute is_nil(dup)
    end

    test "an already-correct entry no longer blocks a real mover from converging on the same destination (U2)" do
      location1 = new_location(%{name: "First"})
      location2 = new_location(%{name: "Second"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})

      # location1's folder already sits exactly at the destination the
      # hook resolves to — a plain no-op that must never block a real
      # mover from landing on the very same {parent, name} pair.
      {:ok, folder1} = Storage.create_folder(%{name: "Same name", parent_uuid: target.uuid})

      {:ok, _location1} =
        Locations.update_location(location1, %{data: %{"files_folder_uuid" => folder1.uuid}})

      {:ok, folder2} = Storage.create_folder(%{name: "location-#{location2.uuid}"})

      {:ok, _location2} =
        Locations.update_location(location2, %{data: %{"files_folder_uuid" => folder2.uuid}})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Same name")
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :duplicate))
      refute Enum.any?(actions, &(&1.kind == :location and &1.label == "First"))

      move = Enum.find(actions, &(&1.kind == :location and &1.label == "Second"))
      refute is_nil(move)
      assert move.op == :move
      assert move.parent_uuid == target.uuid
      assert move.name == "Same name"
    end
  end

  describe "legacy folder relocated elsewhere (locations-specific)" do
    test "legacy folder live under a parent that isn't root or the resolved parent → reported :relocated, not adopted" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Some other container"})

      {:ok, _legacy} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: elsewhere.uuid})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.label == location.name))
      refute is_nil(relocated)
      assert relocated.reason =~ "live under #{elsewhere.name}"
    end

    test "pointer already correct AND a live legacy-named twin exists elsewhere → the twin is reported :relocated" do
      location = new_location(%{name: "Kesklinna kontor"})

      {:ok, real_folder} = Storage.create_folder(%{name: "Somewhere real"})
      {:ok, twin} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => real_folder.uuid}})

      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      # The record's actual (pointer) folder is untouched...
      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
      # ...but the stray legacy-named twin is neither silently dropped
      # nor mistaken for an orphan (the record is alive).
      refute Enum.any?(actions, &(&1.kind == :orphan and &1.folder.uuid == twin.uuid))
      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.label == location.name))
      refute is_nil(relocated)
      assert relocated.folder.uuid == twin.uuid
      assert relocated.reason =~ "live at the media root"
    end

    test "stray legacy-named twin already lives under the resolved target parent → reason warns about the eventual move colliding there" do
      location = new_location(%{name: "Kesklinna kontor"})

      {:ok, real_folder} = Storage.create_folder(%{name: "Somewhere real"})
      {:ok, target} = Storage.create_folder(%{name: "Locations"})

      {:ok, twin} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => real_folder.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      relocated = Enum.find(actions, &(&1.kind == :relocated and &1.label == location.name))
      refute is_nil(relocated)
      assert relocated.folder.uuid == twin.uuid
      assert relocated.reason =~ "already live as a twin under the target parent"
    end
  end

  describe "ambiguous entries still report every extra live copy (U9)" do
    test "host-named + legacy-under-target ambiguity still reports a THIRD live copy as :relocated" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, _host_folder} = Storage.create_folder(%{name: "Nice", parent_uuid: target.uuid})

      {:ok, _legacy_under_target} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

      {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

      {:ok, third_copy} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: elsewhere.uuid})

      Process.put(:target_folder, target.uuid)
      Process.put(:target_name, "Nice")
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_locations, :attachments_folder_name, {Hook, :name})

      actions = MediaReorganizer.plan(nil, [])

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == location.name))
      refute is_nil(dup)

      relocated =
        Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == third_copy.uuid))

      refute is_nil(relocated)
    end

    test "legacy-under-target + legacy-at-root ambiguity still reports a THIRD live copy as :relocated" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})

      {:ok, _under_target} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

      {:ok, _at_root} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      {:ok, elsewhere} = Storage.create_folder(%{name: "Somewhere else"})

      {:ok, third_copy} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: elsewhere.uuid})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == location.name))
      refute is_nil(dup)

      relocated =
        Enum.find(actions, &(&1.kind == :relocated and &1.folder.uuid == third_copy.uuid))

      refute is_nil(relocated)
    end
  end

  describe "the parent hook always sees the FULL record (R9)" do
    test "hook reads a column outside the light select and raises when it's missing → fixed by loading full rows" do
      location = new_location(%{name: "Tallinn HQ", city: "Tallinn"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      Process.put(:target_folder, target.uuid)

      Application.put_env(
        :phoenix_kit_locations,
        :attachments_parent_folder,
        {LocationCityHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      # If the hook only ever saw the light select (no `city` column), it
      # would raise for every candidate and this plan would report nothing
      # but a `hook_error` — proving `city` really reached the hook.
      refute Enum.any?(actions, &(&1.kind == :hook_error))

      action = Enum.find(actions, &(&1.kind == :location and &1.label == location.name))
      refute is_nil(action)
      assert action.op == :move
      assert action.folder.uuid == folder.uuid
      assert action.parent_uuid == target.uuid
    end

    test "space hook resolves a target only when resource.description is set" do
      location = new_location(%{name: "Tallinn HQ"})
      space = new_space(location, %{name: "Floor 1", description: "Ground floor"})

      {:ok, target} = Storage.create_folder(%{name: "Spaces"})
      {:ok, folder} = Storage.create_folder(%{name: "location-space-#{space.uuid}"})

      Process.put(:target_folder, target.uuid)

      Application.put_env(
        :phoenix_kit_locations,
        :attachments_parent_folder,
        {SpaceDescriptionHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      action = Enum.find(actions, &(&1.kind == :space and &1.label == space.name))
      refute is_nil(action)
      assert action.op == :move
      assert action.folder.uuid == folder.uuid
      assert action.parent_uuid == target.uuid
    end
  end

  describe "hook answer casting and normalisation (T1)" do
    test "hook answers {:ok, non-uuid} → hook_error, never a CastError crash" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, _folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      Process.put(:target_folder, "not-a-uuid")
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.op == :report
    end

    test "hook answers {:ok, \"\"} → hook_error, never a CastError crash" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, _folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      Process.put(:target_folder, "")
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location))
      assert Enum.any?(actions, &(&1.kind == :hook_error))
    end

    test "an upper-cased but otherwise unchanged parent answer is a no-op, not a move re-planned every run" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, target} = Storage.create_folder(%{name: "Locations"})

      {:ok, folder} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

      # Pointer already correct AND the folder already sits under `target`
      # (lower-case, canonical) — the only variable left is the hook's
      # answer casing. Without T1's downcase, the pattern match in
      # `noop_move?/3` never sees the two parent uuids as equal and this
      # would be replanned as a move on every single run.
      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

      Process.put(:target_folder, String.upcase(target.uuid))
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
    end
  end

  describe "configured but uncallable hook (T3)" do
    test "hook {mod, fun} where fun is not exported → one hook_error report, distinct from no hook configured" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, _folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      Application.put_env(
        :phoenix_kit_locations,
        :attachments_parent_folder,
        {Hook, :does_not_exist}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "not callable"
    end
  end

  describe "hook config validation is uniform for parent AND name hooks (U7/V3)" do
    test "a garbage (non-tuple) parent hook config → hook_error, never silently 'no hook'" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, _folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, :not_a_tuple)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "not a {module, function} tuple"
    end

    test "a garbage (non-tuple) name hook config → hook_error, record skipped" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})
      Application.put_env(:phoenix_kit_locations, :attachments_folder_name, :not_a_tuple)

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
    end
  end

  describe "an explicit nil answer never moves a folder out of its real parent (F1)" do
    test "folder already lives under a parent; hook answers nil → left in place, reported hook_nil" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, target} = Storage.create_folder(%{name: "Locations"})

      {:ok, folder} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

      # The hook explicitly answers root (nil) for this record.
      Process.put(:target_folder, nil)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.reason =~ "1 record"
    end

    test "folder already at root; hook answers nil → plain no-op, no hook_nil report" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => folder.uuid}})

      Process.put(:target_folder, nil)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :hook_nil))
      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
    end

    test "no pointer, legacy folder already lives under a real parent; hook answers nil → adopted, hook_nil, no :relocated (U1 name track)" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, target} = Storage.create_folder(%{name: "Locations"})

      {:ok, folder} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: target.uuid})

      # No pointer set on the record at all — this candidate is resolved
      # entirely through the NAME track, not the pointer track.
      Process.put(:target_folder, nil)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :relocated))
      hook_nil = Enum.find(actions, &(&1.kind == :hook_nil))
      refute is_nil(hook_nil)
      assert hook_nil.reason =~ "1 record"

      move = Enum.find(actions, &(&1.kind == :location))
      refute is_nil(move)
      assert move.folder.uuid == folder.uuid
      assert move.parent_uuid == target.uuid
      assert is_function(move.after_move, 0)

      assert :ok = move.after_move.()
      reloaded = Locations.get_location(location.uuid)
      assert reloaded.data["files_folder_uuid"] == folder.uuid
    end

    test "no pointer, TWO live legacy copies under two different real parents; hook answers nil → :duplicate naming both, no adoption, no hook_nil (R5-1)" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, parent1} = Storage.create_folder(%{name: "Container one"})
      {:ok, parent2} = Storage.create_folder(%{name: "Container two"})

      {:ok, copy1} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: parent1.uuid})

      {:ok, copy2} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: parent2.uuid})

      # No pointer set on the record — resolved through the name track only.
      Process.put(:target_folder, nil)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      # Neither copy is adopted, nothing is moved, no pointer back-fill, and
      # the record is not counted into the `:hook_nil` report.
      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
      refute Enum.any?(actions, &(&1.kind == :hook_nil))
      refute Enum.any?(actions, &(&1.kind == :relocated and &1.label == location.name))

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == location.name))
      refute is_nil(dup)
      assert dup.reason =~ copy1.uuid
      assert dup.reason =~ copy2.uuid
    end

    test "no pointer, THREE live legacy copies under three real parents; hook answers nil → :duplicate names two, the third is still reported :relocated (R6-1)" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, parent1} = Storage.create_folder(%{name: "Container one"})
      {:ok, parent2} = Storage.create_folder(%{name: "Container two"})
      {:ok, parent3} = Storage.create_folder(%{name: "Container three"})

      copies =
        for parent <- [parent1, parent2, parent3] do
          {:ok, copy} =
            Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: parent.uuid})

          copy
        end

      Process.put(:target_folder, nil)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))
      refute Enum.any?(actions, &(&1.kind == :hook_nil))

      dup = Enum.find(actions, &(&1.kind == :duplicate and &1.label == location.name))
      refute is_nil(dup)

      named_in_dup = Enum.filter(copies, &(dup.reason =~ &1.uuid))
      assert length(named_in_dup) == 2

      [third] = copies -- named_in_dup
      relocated = Enum.filter(actions, &(&1.kind == :relocated))
      assert Enum.any?(relocated, &(&1.folder.uuid == third.uuid))
    end
  end

  describe "every stray legacy copy is reported, not only the first (F5)" do
    test "two live legacy-named twins beside the adopted pointer folder → both reported :relocated" do
      location = new_location(%{name: "Tallinn HQ"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})

      {:ok, real_folder} =
        Storage.create_folder(%{name: "Somewhere real", parent_uuid: target.uuid})

      {:ok, twin1} = Storage.create_folder(%{name: "location-#{location.uuid}"})
      {:ok, elsewhere} = Storage.create_folder(%{name: "Elsewhere"})

      {:ok, twin2} =
        Storage.create_folder(%{name: "location-#{location.uuid}", parent_uuid: elsewhere.uuid})

      {:ok, _location} =
        Locations.update_location(location, %{data: %{"files_folder_uuid" => real_folder.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      # The record's actual (pointer) folder is untouched...
      refute Enum.any?(actions, &(&1.kind == :location and &1.op == :move))

      relocated = Enum.filter(actions, &(&1.kind == :relocated and &1.label == location.name))
      relocated_uuids = relocated |> Enum.map(& &1.folder.uuid) |> Enum.sort()

      assert relocated_uuids == Enum.sort([twin1.uuid, twin2.uuid])
    end
  end

  describe "a failing name hook is a hook_error, never a silent legacy-name fallback (T9/F3)" do
    test "name hook raises → record skipped as hook_error, no move planned" do
      location = new_location(%{name: "Tallinn HQ"})
      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, _folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      Application.put_env(
        :phoenix_kit_locations,
        :attachments_folder_name,
        {RaisingNameHook, :name}
      )

      actions = MediaReorganizer.plan(nil, [])

      refute Enum.any?(actions, &(&1.kind == :location))
      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
    end
  end

  describe "R10 order survives merging the pointer/name tracks (T6)" do
    test "an earlier record resolved by legacy name still precedes a later record resolved via pointer" do
      {:ok, target} = Storage.create_folder(%{name: "Locations"})

      location_a = new_location(%{name: "Alpha"})
      {:ok, _folder_a} = Storage.create_folder(%{name: "location-#{location_a.uuid}"})

      location_b = new_location(%{name: "Beta"})
      {:ok, folder_b} = Storage.create_folder(%{name: "Somewhere for Beta"})

      # `inserted_at` has second precision and both records land in the same
      # second, so the order would fall back to the uuid tiebreak, which
      # UUIDv7 does not guarantee within a millisecond. Pin Alpha as the
      # older record explicitly — the test is about ordering, not about
      # how fast two inserts run.
      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(l in Location, where: l.uuid == ^location_a.uuid),
        set: [inserted_at: old_time]
      )

      {:ok, _location_b} =
        Locations.update_location(location_b, %{data: %{"files_folder_uuid" => folder_b.uuid}})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      location_labels =
        actions |> Enum.filter(&(&1.kind == :location)) |> Enum.map(& &1.label)

      assert Enum.find_index(location_labels, &(&1 == "Alpha")) <
               Enum.find_index(location_labels, &(&1 == "Beta"))
    end

    test "a nested space is listed after its own parent space even when created earlier (U5)" do
      location = new_location(%{name: "Tallinn HQ"})

      parent_space = new_space(location, %{name: "Floor 1", kind: "floor"})

      child_space =
        new_space(location, %{
          name: "Room 101",
          kind: "room",
          parent_uuid: parent_space.uuid
        })

      # Force the child to look OLDER than its parent — proves the order
      # comes from the space tree, not raw `inserted_at`.
      old_time =
        DateTime.utc_now() |> DateTime.add(-10 * 86_400, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(s in Space, where: s.uuid == ^child_space.uuid),
        set: [inserted_at: old_time]
      )

      {:ok, target} = Storage.create_folder(%{name: "Locations"})
      {:ok, _f1} = Storage.create_folder(%{name: "location-space-#{parent_space.uuid}"})
      {:ok, _f2} = Storage.create_folder(%{name: "location-space-#{child_space.uuid}"})

      Process.put(:target_folder, target.uuid)
      Application.put_env(:phoenix_kit_locations, :attachments_parent_folder, {Hook, :parent})

      actions = MediaReorganizer.plan(nil, [])

      space_labels = actions |> Enum.filter(&(&1.kind == :space)) |> Enum.map(& &1.label)

      assert Enum.find_index(space_labels, &(&1 == "Floor 1")) <
               Enum.find_index(space_labels, &(&1 == "Room 101"))
    end
  end

  describe "hook_error / hook_nil reports list record labels, not only a count (U8)" do
    test "hook_error report lists the affected records' labels" do
      location1 = new_location(%{name: "First"})
      location2 = new_location(%{name: "Second"})

      {:ok, target} = Storage.create_folder(%{name: "Locations"})

      {:ok, folder1} =
        Storage.create_folder(%{name: "location-#{location1.uuid}", parent_uuid: target.uuid})

      {:ok, folder2} =
        Storage.create_folder(%{name: "location-#{location2.uuid}", parent_uuid: target.uuid})

      {:ok, _location1} =
        Locations.update_location(location1, %{data: %{"files_folder_uuid" => folder1.uuid}})

      {:ok, _location2} =
        Locations.update_location(location2, %{data: %{"files_folder_uuid" => folder2.uuid}})

      Application.put_env(
        :phoenix_kit_locations,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "2 record(s)"
      assert error.reason =~ "First"
      assert error.reason =~ "Second"
    end

    test "more than 10 affected records → lists the first 10, then a count of the rest" do
      locations =
        for n <- 1..12 do
          location = new_location(%{name: "Location #{n}"})
          {:ok, _folder} = Storage.create_folder(%{name: "location-#{location.uuid}"})
          location
        end

      Application.put_env(
        :phoenix_kit_locations,
        :attachments_parent_folder,
        {RaisingHook, :parent}
      )

      actions = MediaReorganizer.plan(nil, [])

      error = Enum.find(actions, &(&1.kind == :hook_error))
      refute is_nil(error)
      assert error.reason =~ "12 record(s)"
      assert error.reason =~ "… and 2 more"
      assert length(locations) == 12
    end
  end
end
