defmodule PhoenixKitLocations.Errors do
  @moduledoc """
  Central mapping from error atoms (returned by the Locations module's
  public API and used across its LiveViews) to translated human-readable
  strings.

  Keeping UI-facing copy in one place means every "not found" or
  "delete failed" flash reads the same wording, and translations live
  in core's gettext backend rather than being scattered across call
  sites. Callers pattern-match on atoms; `message/1` wraps each mapping
  in `gettext/1` at the UI boundary.

  ## Supported reason shapes

    * plain atoms — `:location_not_found`, `:type_assignment_failed`, etc.
    * strings — passed through unchanged (legacy / interpolated messages)
    * anything else — rendered as `"Unexpected error: <inspect>"` so
      nothing silently surfaces a raw struct

  ## Example

      iex> PhoenixKitLocations.Errors.message(:location_not_found)
      "Location not found."
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc """
  Translates an error reason into a user-facing string via gettext.
  """
  @spec message(term()) :: String.t()
  def message(:location_not_found), do: gettext("Location not found.")
  def message(:location_type_not_found), do: gettext("Location type not found.")
  def message(:location_delete_failed), do: gettext("Failed to delete location.")
  def message(:location_type_delete_failed), do: gettext("Failed to delete location type.")

  def message(:type_assignment_failed),
    do: gettext("Saved but failed to update type assignments.")

  def message(:unexpected), do: gettext("An unexpected error occurred.")

  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end
end
