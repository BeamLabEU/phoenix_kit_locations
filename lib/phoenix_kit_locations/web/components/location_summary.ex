defmodule PhoenixKitLocations.Web.Components.LocationSummary do
  @moduledoc "Compact location identity shared by directory rows, cards and project sites."
  use Phoenix.Component

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, URLSigner}
  alias PhoenixKitLocations.{Geo, Spaces}

  @doc """
  Resolves live listing covers in one batch, respecting private library access.

  Any failure becomes `%{}`. The project Sites tab has no other guard, and a
  cover lookup must not take down the host project page.
  """
  def cover_urls(locations, scope) do
    locations
    |> Enum.map(&cover_uuid/1)
    |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))
    |> Enum.uniq()
    |> Storage.get_files()
    |> Map.new(fn file -> {file.uuid, cover_url(file, scope)} end)
  rescue
    exception ->
      Logger.warning("Cannot load location covers: #{Exception.message(exception)}")
      %{}
  catch
    kind, reason ->
      Logger.warning("Cannot load location covers: #{inspect({kind, reason})}")
      %{}
  end

  defp cover_uuid(%{data: data}) when is_map(data), do: data["featured_image_uuid"]
  defp cover_uuid(_location), do: nil

  defp cover_url(%{file_type: "image", status: "active"} = file, scope) do
    if Libraries.private_file?(file),
      do: Storage.authorized_url(scope, file, "thumbnail"),
      else: URLSigner.signed_url(file.uuid, "thumbnail")
  rescue
    exception ->
      Logger.warning("Cannot sign location cover #{file.uuid}: #{Exception.message(exception)}")
      nil
  end

  defp cover_url(_file, _scope), do: nil

  attr(:location, :map, required: true)
  attr(:cover_urls, :map, required: true)
  attr(:locale, :string, default: nil)

  def location_summary(assigns) do
    location = assigns.location

    address =
      [location.address_line_1, location.city, Geo.country_name(location.country)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(", ")

    assigns =
      assign(assigns,
        address: address,
        cover: assigns.cover_urls[get_in(location.data, ["featured_image_uuid"])]
      )

    ~H"""
    <span class="flex items-center gap-3">
      <img
        :if={@cover}
        src={@cover}
        alt=""
        loading="lazy"
        class="size-12 shrink-0 rounded-md object-cover"
      />
      <span class="min-w-0">
        <span class="block font-medium">{Spaces.translated_name(@location, @locale)}</span>
        <span :if={@address != ""} class="block text-sm text-base-content/70">{@address}</span>
      </span>
    </span>
    """
  end
end
