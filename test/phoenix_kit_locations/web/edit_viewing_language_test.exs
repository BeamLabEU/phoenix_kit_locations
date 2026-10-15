defmodule PhoenixKitLocations.Web.EditViewingLanguageTest do
  @moduledoc """
  The location and location-type forms open an EDIT on the language tab of
  the language the admin is viewing the page in; a new record starts on the
  main language, which holds its required fields.
  """
  use PhoenixKitLocations.LiveCase

  alias PhoenixKit.Modules.Languages

  setup %{conn: conn} do
    {:ok, _} = Languages.enable_system()
    {:ok, _} = Languages.add_language("fr-FR")

    conn =
      conn
      |> put_test_scope(fake_scope())
      |> with_request_locale("fr-FR")

    %{conn: conn, location: fixture_location(), type: fixture_location_type()}
  end

  defp open_lang(view), do: :sys.get_state(view.pid).socket.assigns.current_lang

  test "viewed in French, the edit forms open on the French tab", ctx do
    for path <- [
          "/admin/locations/#{ctx.location.uuid}/edit",
          "/admin/locations/types/#{ctx.type.uuid}/edit"
        ] do
      {:ok, view, _html} = live(ctx.conn, path)
      assert open_lang(view) == "fr-FR", path
    end
  end

  test "viewed in French, a new record starts on the main tab", ctx do
    for path <- ["/admin/locations/new", "/admin/locations/types/new"] do
      {:ok, view, _html} = live(ctx.conn, path)
      assert open_lang(view) == "en-US", path
    end
  end
end
