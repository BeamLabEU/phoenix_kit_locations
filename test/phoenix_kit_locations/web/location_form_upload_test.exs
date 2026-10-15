defmodule PhoenixKitLocations.Web.LocationFormUploadTest do
  @moduledoc """
  An upload through the location form's real file input: stored under
  its base name, filed into the location's folder, and a byte-identical
  re-upload is reported instead of passing silently as a success.
  """
  use PhoenixKitLocations.LiveCase, async: false

  import ExUnit.CaptureLog

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKitLocations.Test.Repo

  @buckets_cache :phoenix_kit_buckets_cache

  setup %{conn: conn} do
    :persistent_term.erase(@buckets_cache)
    # Stored files go to every enabled bucket; keep them all in this one.
    # Core refuses to disable a bucket a storage profile still lists, so take
    # each out of the Default profile first.
    default_profile = Profiles.default_profile()

    for bucket <- Storage.list_enabled_buckets() do
      :ok = Profiles.remove_bucket(default_profile, bucket.uuid)
      {:ok, _} = Storage.update_bucket(bucket, %{enabled: false})
    end

    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "locations_upload_#{n}")

    {:ok, _bucket} =
      Storage.create_bucket(%{
        name: "locations-upload-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn ->
      :persistent_term.erase(@buckets_cache)
      File.rm_rf(root)
    end)

    # Stored files belong to a real user row.
    user_uuid = UUIDv7.generate()

    SQL.query!(
      Repo,
      """
      INSERT INTO phoenix_kit_users
        (uuid, email, hashed_password, account_type, is_active, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'person', true, NOW(), NOW())
      """,
      [
        Ecto.UUID.dump!(user_uuid),
        "upload-#{n}@example.com",
        "$2b$12$0000000000000000000000000000000000000000000000000000."
      ]
    )

    %{conn: put_test_scope(conn, fake_scope(user_uuid: user_uuid))}
  end

  # Variant jobs cannot be queued without Oban; that is logged, not raised.
  defp upload(view, name, content) do
    render_click(view, "set_active_upload_scope", %{"scope" => "location"})

    file =
      file_input(view, "#location-form", :attachment_files, [
        %{last_modified: 1_700_000_000_000, name: name, content: content, type: "application/pdf"}
      ])

    capture_log(fn -> render_upload(file, name) end)
    render(view)
  end

  test "the dropzone carries the bundled scope hook", %{conn: conn} do
    location = fixture_location()
    {:ok, view, _html} = live(conn, "/admin/locations/#{location.uuid}/edit")

    assert has_element?(
             view,
             "label[id^='pk-locations-dropzone-'][phx-hook='PhoenixKitLocationsUploadScope']"
           )
  end

  test "an upload lands in the location's folder, and a duplicate is reported", %{conn: conn} do
    location = fixture_location(%{name: "Upload HQ"})
    {:ok, view, _html} = live(conn, "/admin/locations/#{location.uuid}/edit")

    html = upload(view, "../../plan.pdf", "plan #{location.uuid}")

    assert [file] = files_named(["plan.pdf", "../../plan.pdf"])
    assert file.original_file_name == "plan.pdf"
    assert file.file_type == "document"
    # Filed in the folder the location now points at.
    assert file.folder_uuid == Repo.reload(location).data["files_folder_uuid"]
    assert html =~ "plan.pdf"
    refute html =~ "flash-error"

    html = upload(view, "copy.pdf", "plan #{location.uuid}")

    assert html =~
             "copy.pdf is identical to plan.pdf, which is already attached — nothing was added."

    assert [^file] = files_named(["plan.pdf", "copy.pdf"])
  end

  test "an upload that cannot be filed says so and leaves the list", %{conn: conn} do
    location = fixture_location()
    {:ok, view, _html} = live(conn, "/admin/locations/#{location.uuid}/edit")

    # No file area was chosen (the scope hook never fired).
    file =
      file_input(view, "#location-form", :attachment_files, [
        %{
          last_modified: 1_700_000_000_000,
          name: "lost.pdf",
          content: "x",
          type: "application/pdf"
        }
      ])

    capture_log(fn -> render_upload(file, "lost.pdf") end)
    html = render(view)

    assert html =~ "Upload failed: no target file area selected."
    # Not left in the list at 100%, counting against the upload limit.
    refute html =~ "lost.pdf"
    assert files_named(["lost.pdf"]) == []
  end

  defp files_named(names),
    do: Repo.all(from(f in StorageFile, where: f.original_file_name in ^names))
end
