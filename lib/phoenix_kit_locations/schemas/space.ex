defmodule PhoenixKitLocations.Schemas.Space do
  @moduledoc """
  A nested space inside a `Location` — a floor, room, zone, etc.

  Spaces form a filesystem-like tree per Location: each row belongs to
  exactly one Location (required FK) and may optionally belong to a
  parent Space (self-ref FK), forming arbitrary-depth nesting.

  ## Translatable fields

  `name` and `description` are translatable. Primary-language values
  stay in the dedicated columns; secondary languages live under a
  language-code key in `data`, e.g.:

      %{ "es-ES" => %{ "name" => "Planta 2" } }

  Top-level keys in `data` carry attachment pointers
  (`files_folder_uuid`, `featured_image_uuid`), mirroring how
  `phoenix_kit_locations.data` is used.

  ## Kind

  `kind` is a fixed string from `@kinds`. The DB CHECK constraint in
  V122 mirrors the same list — keep both in sync if a new label is
  added.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset
  use Gettext, backend: PhoenixKitLocations.Gettext

  alias PhoenixKitLocations.Schemas.Location

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  # The Spaces tree exposes six kinds: floor and room (top-level
  # subdivisions of a location) plus zone/section/aisle/shelf for
  # finer-grained subdivisions (production zones/sections, warehouse
  # addressable storage). The DB CHECK constraint (V122 in core)
  # intentionally still allows a wider set (hall, suite, corner)
  # reserved for future growth without an immediate migration —
  # narrowing to the app-layer list happens here.
  @kinds ~w(floor room zone section aisle shelf)
  @statuses ~w(active inactive)

  schema "phoenix_kit_location_spaces" do
    field(:kind, :string)
    field(:name, :string)
    field(:description, :string)
    field(:notes, :string)
    field(:status, :string, default: "active")
    field(:position, :integer, default: 0)
    field(:data, :map, default: %{})

    belongs_to(:location, Location, foreign_key: :location_uuid, references: :uuid)
    belongs_to(:parent, __MODULE__, foreign_key: :parent_uuid, references: :uuid)

    has_many(:children, __MODULE__,
      foreign_key: :parent_uuid,
      references: :uuid
    )

    timestamps(type: :utc_datetime)
  end

  @required_fields [:location_uuid, :kind, :name]
  @optional_fields [
    :parent_uuid,
    :description,
    :notes,
    :status,
    :position,
    :data
  ]

  @doc """
  Form-facing changeset.

  Note: the "child belongs to the same Location as its parent"
  guarantee is enforced in the `PhoenixKitLocations.Spaces` context,
  not here — the schema doesn't have parent context to compare
  against without an extra DB read. Keep that invariant load-bearing
  on the context.
  """
  def changeset(space, attrs) do
    space
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:description, max: 2000)
    |> validate_length(:notes, max: 5000)
    |> validate_no_self_parent()
    |> assoc_constraint(:location)
    |> assoc_constraint(:parent)
    |> check_constraint(:kind,
      name: :phoenix_kit_location_spaces_kind_check,
      message: gettext("must be one of: %{values}", values: Enum.join(@kinds, ", "))
    )
    |> check_constraint(:status,
      name: :phoenix_kit_location_spaces_status_check,
      message: gettext("must be one of: %{values}", values: Enum.join(@statuses, ", "))
    )
  end

  # Mirrors the DB self-ref FK's "no cycles via direct self-loop" guard.
  # Doesn't catch indirect cycles (A → B → A) — that's a context-layer
  # check before any UPDATE that re-parents a node.
  defp validate_no_self_parent(changeset) do
    case {get_field(changeset, :uuid), get_change(changeset, :parent_uuid)} do
      {nil, _} -> changeset
      {_, nil} -> changeset
      {uuid, uuid} -> add_error(changeset, :parent_uuid, gettext("cannot be its own parent"))
      _ -> changeset
    end
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc """
  Human-readable label for a `kind` value, translated via the module's
  own Gettext backend. Falls back to the raw kind string for anything
  outside `@kinds` (e.g. reserved-but-unused DB CHECK values).
  """
  @spec kind_label(String.t()) :: String.t()
  def kind_label("floor"), do: gettext("Floor")
  def kind_label("room"), do: gettext("Room")
  def kind_label("zone"), do: gettext("Zone")
  def kind_label("section"), do: gettext("Section")
  def kind_label("aisle"), do: gettext("Aisle")
  def kind_label("shelf"), do: gettext("Shelf")
  def kind_label(kind), do: kind

  @doc """
  Heroicon name for a `kind` value, used by the Spaces tree UI.
  Falls back to a generic cube icon for anything outside `@kinds`.
  """
  @spec kind_icon(String.t()) :: String.t()
  def kind_icon("floor"), do: "hero-building-office-2"
  def kind_icon("room"), do: "hero-squares-2x2"
  def kind_icon("zone"), do: "hero-map"
  def kind_icon("section"), do: "hero-view-columns"
  def kind_icon("aisle"), do: "hero-arrows-right-left"
  def kind_icon("shelf"), do: "hero-archive-box"
  def kind_icon(_kind), do: "hero-cube"
end
