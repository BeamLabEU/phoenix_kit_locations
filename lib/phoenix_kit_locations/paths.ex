defmodule PhoenixKitLocations.Paths do
  @moduledoc """
  Centralized path helpers for the Locations module.

  All paths go through `PhoenixKit.Utils.Routes.path/1` for prefix/locale handling.
  """

  alias PhoenixKit.Utils.Routes

  @base "/admin/locations"

  # ── Locations ─────────────────────────────────────────────────────

  def index, do: Routes.path(@base)
  def location_new, do: Routes.path("#{@base}/new")
  def location_edit(uuid), do: Routes.path("#{@base}/#{uuid}/edit")

  # ── Types ─────────────────────────────────────────────────────────

  def types, do: Routes.path("#{@base}/types")
  def type_new, do: Routes.path("#{@base}/types/new")
  def type_edit(uuid), do: Routes.path("#{@base}/types/#{uuid}/edit")
end
