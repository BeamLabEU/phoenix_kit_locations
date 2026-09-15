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

  def message(:not_allowed), do: gettext("You don't have permission to do that.")

  def message(:owner_update_failed),
    do: gettext("Saved, but failed to change the owner.")

  def message(:space_not_found), do: gettext("Space not found.")

  def message(:parent_in_other_location),
    do: gettext("The chosen parent space belongs to a different location.")

  def message(:parent_not_found),
    do: gettext("The chosen parent space no longer exists.")

  def message(:cycle),
    do: gettext("Cannot make a space its own ancestor.")

  def message(:parent_floor_unsaved),
    do: gettext("its parent floor was not saved (it might need a name)")

  def message(:unexpected), do: gettext("An unexpected error occurred.")

  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end
end
