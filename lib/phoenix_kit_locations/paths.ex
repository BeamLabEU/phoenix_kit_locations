defmodule PhoenixKitLocations.Paths do
  @moduledoc """
  Centralized path helpers for the Locations module.

  All paths go through `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/locations"

  # ── Locations ─────────────────────────────────────────────────────

  @spec index() :: String.t()
  def index, do: Routes.path(@base)

  @spec location_new() :: String.t()
  def location_new, do: Routes.path("#{@base}/new")

  @spec location_edit(String.t()) :: String.t()
  def location_edit(uuid), do: Routes.path("#{@base}/#{uuid}/edit")

  @doc "The edit page opened on one of its panels: `basics`, `details` or `settings`."
  @spec location_edit(String.t(), String.t()) :: String.t()
  def location_edit(uuid, tab), do: location_edit(uuid) <> "?tab=" <> URI.encode_www_form(tab)

  @spec location_structure(String.t()) :: String.t()
  def location_structure(uuid), do: Routes.path("#{@base}/#{uuid}/structure")

  # ── Types ─────────────────────────────────────────────────────────

  @spec types() :: String.t()
  def types, do: Routes.path("#{@base}/types")

  @spec type_new() :: String.t()
  def type_new, do: Routes.path("#{@base}/types/new")

  @spec type_edit(String.t()) :: String.t()
  def type_edit(uuid), do: Routes.path("#{@base}/types/#{uuid}/edit")
end
