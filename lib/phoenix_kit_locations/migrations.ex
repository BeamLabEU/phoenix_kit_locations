defmodule PhoenixKitLocations.Migrations do
  @moduledoc """
  Module-owned versioned migrations for `phoenix_kit_locations` — the
  decentralized-migrations protocol that core's `mix phoenix_kit.update`
  discovers via `migration_module/0`: `current_version/0` +
  `migrated_version_runtime/1` + idempotent `up/1` + version-aware
  `down/1`. `phoenix_kit_legal` (one adopted table) and
  `phoenix_kit_catalogue` (eighteen) are the sibling chains in exactly this
  situation.

  ## What V1 is

  V1 is an ADOPTION step for the four tables core already creates in its
  squashed V135 baseline: `phoenix_kit_locations`,
  `phoenix_kit_location_types`, `phoenix_kit_location_type_assignments`,
  `phoenix_kit_location_spaces`. No core version after V135 reshapes any of
  them, so V135 is the whole shape authority.

    * On every existing install the tables are already there: the `CREATE
      TABLE IF NOT EXISTS` statements and the guarded `DO $$ ... pg_constraint
      ... $$` blocks all find their targets and are no-ops. The only new
      object is the `pkloc_schema:1` marker; from then on this chain owns the
      tables' future shape.
    * On a fresh install whose core baseline no longer creates them (the
      next squash), the same statements create them, shape-identical to
      V135 with core's exact table, constraint and index names.

  `CREATE TABLE IF NOT EXISTS` is a presence check only; it does not repair a
  drifted column. The guarded constraint blocks DO repair a missing key,
  FK or CHECK on an existing table. Core's chain always runs before this one
  (`mix phoenix_kit.update` applies core first), so by the time V1 runs the
  tables are at V135 shape.

  Because V1 changes no shape, core's `ExpectedSchema` manifest (which still
  audits these tables as `owner: :locations`) stays accurate and no core
  release is required. A version that DOES change shape (V2+) must, before it
  ships, add the altered objects to core's manifest generator
  `@excluded_exact` and regenerate `ExpectedSchema`, then raise this package's
  core floor to that release; otherwise `mix phoenix_kit.repair` restores the
  V135 shape. See `phoenix_kit_legal`'s
  `dev_docs/reports/2026-08-10-consent-logs-extraction.md`.

  ## What V2 is

  Location ownership: a nullable `owner_uuid` column on
  `phoenix_kit_locations`, a foreign key to `phoenix_kit_users(uuid)` with
  `ON DELETE CASCADE` (deleting a user deletes the locations they own, and
  through the existing cascades their type assignments and space trees), and
  a btree index on the column.

  V2 only ADDS objects core's `ExpectedSchema` manifest never names (the
  manifest resolver iterates its declared objects and never enumerates a
  table's actual columns), so no core release or manifest exclusion is
  needed — the same reasoning as `phoenix_kit_catalogue`'s V2 slug column.

  ## What `down/1` is NOT

  `down/1` rewrites the version marker; it NEVER drops a table. The rows are
  hand-curated reference data and, on every current install, the tables are
  core-created. `test/phoenix_kit_locations/migrations_test.exs` pins this by
  asserting no statement this module can emit matches `DROP`, `TRUNCATE` or
  `DELETE`. Rolling back to V1 re-stamps the marker and leaves the nullable
  `owner_uuid` column, its FK and index in place.

  ## Adding a version

  1. Append the new statements to `up_statements/2` behind `target >= N`
     (never edit V1's statements: hosts past V1 never re-run them).
  2. Bump `@current_version`.
  3. Follow the V2+ core-manifest step above before releasing.

  The migrated version is tracked as a `pkloc_schema:<N>` `COMMENT ON TABLE`
  marker on `phoenix_kit_locations` (the namespaced marker convention from
  the projects/legal/catalogue chains). A marker-less table reads as version
  0 — the core-baseline shape before this chain existed.
  """

  use Ecto.Migration

  @current_version 2
  @marker_prefix "pkloc_schema:"
  @version_table "phoenix_kit_locations"

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @doc "The table carrying the `pkloc_schema:<N>` marker (auditor contract)."
  @spec version_table() :: String.t()
  def version_table, do: @version_table

  @doc "The chain version read from INSIDE a migration (migration repo)."
  def migrated_version(opts \\ []) do
    prefix = validated_prefix(opts)
    %{rows: rows} = repo().query!(marker_query(), [prefix])
    rows |> List.first() |> marker_to_version()
  end

  @doc """
  The chain version currently applied in the database, read OUTSIDE a
  migration (the protocol shape core's update task calls — `opts` with
  `:prefix`): the `pkloc_schema:<N>` marker when present; a marker-less or
  foreign-comment table reads as `0` (core-baseline shape — V1 is purely
  adoptive, there is no pre-chain content to defend).

  `catch :exit` matters as much as `rescue`: a dead or unstarted pool exits
  rather than raising, and `mix phoenix_kit.status` calls this across every
  installed module.
  """
  def migrated_version_runtime(opts \\ []) do
    prefix = validated_prefix(opts)

    case PhoenixKit.RepoHelper.repo().query(marker_query(), [prefix]) do
      {:ok, %{rows: rows}} -> rows |> List.first() |> marker_to_version()
      _ -> 0
    end
  rescue
    # An invalid prefix must surface as the validation error, not be
    # swallowed into 0 ("not installed").
    e in ArgumentError -> reraise e, __STACKTRACE__
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc "Applies every chain version up to `target` (`:version` in `opts`, default `current_version/0`); idempotent."
  def up(opts \\ []) do
    prefix = validated_prefix(opts)

    target =
      if is_list(opts), do: Keyword.get(opts, :version, @current_version), else: @current_version

    prefix
    |> up_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc "Rolls back to `target` (`:version` in `opts`). Never drops a table — see the moduledoc."
  def down(opts \\ []) do
    prefix = validated_prefix(opts)
    target = if is_list(opts), do: Keyword.get(opts, :version, 0), else: 0

    prefix
    |> down_statements(target)
    |> Enum.each(&execute/1)
  end

  @doc """
  The SQL `up/1` executes, as data — the testable single source. Every
  statement is idempotent (`IF NOT EXISTS` / guarded `DO $$` block /
  `COMMENT`), so it is safe to replay on an install where core already
  created the tables and on a fresh install with none of them.

  V1 order: every `CREATE TABLE`, then every primary-key guard, then every
  foreign-key guard, then every CHECK guard, then every index, then the
  version marker last. FK guards run after all tables exist, so table order
  is self-documentation only.

  `target` selects how much of the chain to emit (default
  `current_version/0`); the wrapper migration core's update task generates
  passes an explicit `:version`, and a stale wrapper asking for an older
  version must not receive a newer version's objects.
  """
  @spec up_statements(String.t(), pos_integer()) :: [String.t()]
  def up_statements(prefix \\ "public", target \\ @current_version)

  def up_statements(prefix, target) when is_integer(target) and target >= 1 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."
    target = min(target, @current_version)

    v2 = if target >= 2, do: v2_statements(prefix, p), else: []

    List.flatten([
      v1_statements(prefix, p),
      v2,
      "COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"
    ])
  end

  @doc "The SQL `down/1` executes, as data (marker bookkeeping only)."
  @spec down_statements(String.t(), non_neg_integer()) :: [String.t()]
  def down_statements(prefix \\ "public", target \\ 0)
      when is_integer(target) and target >= 0 do
    prefix = validated_prefix(prefix: prefix)
    p = "#{prefix}."

    if target > 0 do
      ["COMMENT ON TABLE #{p}#{@version_table} IS '#{@marker_prefix}#{target}'"]
    else
      ["COMMENT ON TABLE #{p}#{@version_table} IS NULL"]
    end
  end

  # ── V1: adoption of core V135's four tables ─────────────────────────────

  defp v1_statements(prefix, p) do
    [
      tables(p),
      primary_keys(prefix, p),
      foreign_keys(prefix, p),
      checks(prefix, p),
      indexes(p)
    ]
  end

  # ── V2: location ownership ──────────────────────────────────────────────

  defp v2_statements(prefix, p) do
    [
      "ALTER TABLE #{p}phoenix_kit_locations ADD COLUMN IF NOT EXISTS owner_uuid uuid",
      guarded_constraint(
        prefix,
        "phoenix_kit_locations",
        "phoenix_kit_locations_owner_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_locations ADD CONSTRAINT phoenix_kit_locations_owner_uuid_fkey FOREIGN KEY (owner_uuid) REFERENCES #{p}phoenix_kit_users(uuid) ON DELETE CASCADE"
      ),
      "CREATE INDEX IF NOT EXISTS phoenix_kit_locations_owner_uuid_index ON #{p}phoenix_kit_locations USING btree (owner_uuid)"
    ]
  end

  # Column lists, types, defaults and order are verbatim from core V135.
  defp tables(p) do
    [
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_locations (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "name" character varying(255) NOT NULL,
        "description" text,
        "public_notes" text,
        "address_line_1" character varying(500),
        "address_line_2" character varying(500),
        "city" character varying(255),
        "state" character varying(255),
        "postal_code" character varying(20),
        "country" character varying(255),
        "phone" character varying(50),
        "email" character varying(255),
        "website" character varying(500),
        "notes" text,
        "status" character varying(20) DEFAULT 'active'::character varying,
        "features" jsonb DEFAULT '{}'::jsonb,
        "data" jsonb DEFAULT '{}'::jsonb,
        "inserted_at" timestamp(0) without time zone NOT NULL,
        "updated_at" timestamp(0) without time zone NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_location_types (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "name" character varying(255) NOT NULL,
        "description" text,
        "status" character varying(20) DEFAULT 'active'::character varying,
        "data" jsonb DEFAULT '{}'::jsonb,
        "inserted_at" timestamp(0) without time zone NOT NULL,
        "updated_at" timestamp(0) without time zone NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_location_type_assignments (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "location_uuid" uuid NOT NULL,
        "location_type_uuid" uuid NOT NULL,
        "inserted_at" timestamp(0) without time zone NOT NULL,
        "updated_at" timestamp(0) without time zone NOT NULL
      )
      """,
      """
      CREATE TABLE IF NOT EXISTS #{p}phoenix_kit_location_spaces (
        "uuid" uuid DEFAULT #{p}uuid_generate_v7() NOT NULL,
        "location_uuid" uuid NOT NULL,
        "parent_uuid" uuid,
        "kind" character varying(32) NOT NULL,
        "name" character varying(255) NOT NULL,
        "description" text,
        "notes" text,
        "status" character varying(20) DEFAULT 'active'::character varying NOT NULL,
        "position" integer DEFAULT 0 NOT NULL,
        "data" jsonb DEFAULT '{}'::jsonb NOT NULL,
        "inserted_at" timestamp(0) without time zone NOT NULL,
        "updated_at" timestamp(0) without time zone NOT NULL
      )
      """
    ]
  end

  defp primary_keys(prefix, p) do
    for table <- ~w(phoenix_kit_locations phoenix_kit_location_types
                    phoenix_kit_location_type_assignments phoenix_kit_location_spaces) do
      guarded_constraint(
        prefix,
        table,
        "#{table}_pkey",
        "ALTER TABLE #{p}#{table} ADD CONSTRAINT #{table}_pkey PRIMARY KEY (uuid)"
      )
    end
  end

  # All four cascade: deleting a location removes its type assignments and
  # its whole space subtree (the context layer relies on this).
  defp foreign_keys(prefix, p) do
    [
      guarded_constraint(
        prefix,
        "phoenix_kit_location_type_assignments",
        "phoenix_kit_location_type_assignments_location_type_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_location_type_assignments ADD CONSTRAINT phoenix_kit_location_type_assignments_location_type_uuid_fkey FOREIGN KEY (location_type_uuid) REFERENCES #{p}phoenix_kit_location_types(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_location_type_assignments",
        "phoenix_kit_location_type_assignments_location_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_location_type_assignments ADD CONSTRAINT phoenix_kit_location_type_assignments_location_uuid_fkey FOREIGN KEY (location_uuid) REFERENCES #{p}phoenix_kit_locations(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_location_spaces",
        "phoenix_kit_location_spaces_location_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_location_spaces ADD CONSTRAINT phoenix_kit_location_spaces_location_uuid_fkey FOREIGN KEY (location_uuid) REFERENCES #{p}phoenix_kit_locations(uuid) ON DELETE CASCADE"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_location_spaces",
        "phoenix_kit_location_spaces_parent_uuid_fkey",
        "ALTER TABLE #{p}phoenix_kit_location_spaces ADD CONSTRAINT phoenix_kit_location_spaces_parent_uuid_fkey FOREIGN KEY (parent_uuid) REFERENCES #{p}phoenix_kit_location_spaces(uuid) ON DELETE CASCADE"
      )
    ]
  end

  # The kind CHECK is deliberately wider than `Space.kinds/0` (hall, suite,
  # corner are reserved) — see `dev_docs/guides/spaces.md`.
  defp checks(prefix, p) do
    [
      guarded_constraint(
        prefix,
        "phoenix_kit_location_spaces",
        "phoenix_kit_location_spaces_kind_check",
        "ALTER TABLE #{p}phoenix_kit_location_spaces ADD CONSTRAINT phoenix_kit_location_spaces_kind_check CHECK (((kind)::text = ANY ((ARRAY['floor'::character varying, 'room'::character varying, 'hall'::character varying, 'suite'::character varying, 'section'::character varying, 'zone'::character varying, 'aisle'::character varying, 'shelf'::character varying, 'corner'::character varying])::text[])))"
      ),
      guarded_constraint(
        prefix,
        "phoenix_kit_location_spaces",
        "phoenix_kit_location_spaces_status_check",
        "ALTER TABLE #{p}phoenix_kit_location_spaces ADD CONSTRAINT phoenix_kit_location_spaces_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'inactive'::character varying])::text[])))"
      )
    ]
  end

  # Index names are core's, including the two Postgres truncated at 63 bytes.
  # They stay bare on CREATE (an index lives in its table's schema).
  defp indexes(p) do
    [
      "CREATE INDEX IF NOT EXISTS phoenix_kit_locations_status_index ON #{p}phoenix_kit_locations USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_location_types_status_index ON #{p}phoenix_kit_location_types USING btree (status)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_location_type_assignments_location_uuid_index ON #{p}phoenix_kit_location_type_assignments USING btree (location_uuid)",
      "CREATE UNIQUE INDEX IF NOT EXISTS phoenix_kit_location_type_assignments_location_uuid_location_ty ON #{p}phoenix_kit_location_type_assignments USING btree (location_uuid, location_type_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_location_spaces_location_uuid_index ON #{p}phoenix_kit_location_spaces USING btree (location_uuid)",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_location_spaces_location_uuid_parent_uuid_position_ ON #{p}phoenix_kit_location_spaces USING btree (location_uuid, parent_uuid, \"position\")",
      "CREATE INDEX IF NOT EXISTS phoenix_kit_location_spaces_parent_uuid_index ON #{p}phoenix_kit_location_spaces USING btree (parent_uuid)"
    ]
  end

  defp guarded_constraint(prefix, table, constraint_name, add_sql) do
    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_namespace n ON n.oid = t.relnamespace
        WHERE c.conname = '#{constraint_name}'
          AND t.relname = '#{table}'
          AND n.nspname = '#{prefix}'
      ) THEN
        #{add_sql};
      END IF;
    END
    $$
    """
  end

  defp marker_query do
    """
    SELECT d.description
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_description d
      ON d.objoid = c.oid AND d.objsubid = 0 AND d.classoid = 'pg_class'::regclass
    WHERE n.nspname = $1 AND c.relname = '#{@version_table}' AND c.relkind = 'r'
    """
  end

  defp marker_to_version([@marker_prefix <> n]) do
    case Integer.parse(n) do
      {v, ""} when v >= 0 -> v
      _ -> 0
    end
  end

  defp marker_to_version(_), do: 0

  defp validated_prefix(opts) do
    prefix =
      case opts do
        opts when is_list(opts) -> Keyword.get(opts, :prefix) || "public"
        %{prefix: prefix} when is_binary(prefix) -> prefix
        _ -> "public"
      end

    # Interpolated into DDL and into the guard blocks' string literals.
    unless prefix =~ ~r/^[a-zA-Z_][a-zA-Z0-9_]*$/ do
      raise ArgumentError, "invalid schema prefix: #{inspect(prefix)}"
    end

    prefix
  end
end
