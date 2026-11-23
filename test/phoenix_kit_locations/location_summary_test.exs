defmodule PhoenixKitLocations.LocationSummaryTest do
  @moduledoc """
  Cover lookup for list rows and the project Sites tab. No database: an empty
  or invalid uuid list never reaches Storage.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitLocations.Web.Components.LocationSummary

  test "cover_urls ignores missing and malformed covers" do
    locations = [
      %{data: nil},
      %{},
      %{data: %{"featured_image_uuid" => "not-a-uuid"}}
    ]

    assert LocationSummary.cover_urls(locations, nil) == %{}
  end

  test "cover_urls returns an empty map when the lookup fails" do
    assert LocationSummary.cover_urls(:not_a_list, nil) == %{}
  end
end
