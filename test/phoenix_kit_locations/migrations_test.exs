defmodule PhoenixKitLocations.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.ExpectedSchema.Resolver
  alias PhoenixKitLocations.Migrations
  alias PhoenixKitLocations.Schemas.Space

  @tables ~w(
    phoenix_kit_locations
    phoenix_kit_location_types
    phoenix_kit_location_type_assignments
    phoenix_kit_location_spaces
  )

  # Every index this chain owns: core V135's seven, then V2's owner index. The
  # "guarded" test below only scans statements that exist, so without this
  # list all of them could be deleted and it would still pass.
  @indexes ~w(
    phoenix_kit_locations_status_index
    phoenix_kit_location_types_status_index
    phoenix_kit_location_type_assignments_location_uuid_index
    phoenix_kit_location_type_assignments_location_uuid_location_ty
    phoenix_kit_location_spaces_location_uuid_index
    phoenix_kit_location_spaces_location_uuid_parent_uuid_position_
    phoenix_kit_location_spaces_parent_uuid_index
    phoenix_kit_locations_owner_uuid_index
  )

  # All 11 constraint names: V135's 4 PKs + 4 FKs + 2 CHECKs, then V2's owner FK.
  @constraints ~w(
    phoenix_kit_locations_owner_uuid_fkey
    phoenix_kit_locations_pkey
    phoenix_kit_location_types_pkey
    phoenix_kit_location_type_assignments_pkey
    phoenix_kit_location_spaces_pkey
    phoenix_kit_location_type_assignments_location_type_uuid_fkey
    phoenix_kit_location_type_assignments_location_uuid_fkey
    phoenix_kit_location_spaces_location_uuid_fkey
    phoenix_kit_location_spaces_parent_uuid_fkey
    phoenix_kit_location_spaces_kind_check
    phoenix_kit_location_spaces_status_check
  )

  test "chain is V2 and marks phoenix_kit_locations" do
    assert Migrations.current_version() == 2
    assert Migrations.version_table() == "phoenix_kit_locations"
  end

  test "the module registers the chain" do
    assert PhoenixKitLocations.migration_module() == Migrations
  end

  test "up_statements creates every owned table idempotently and stamps the marker" do
    stmts = Migrations.up_statements("public")

    for t <- @tables do
      assert Enum.any?(stmts, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{t} (")),
             "missing CREATE TABLE for #{t}"
    end

    assert Enum.count(stmts, &(&1 =~ ~r/CREATE TABLE/)) == length(@tables)

    assert List.last(stmts) ==
             "COMMENT ON TABLE public.phoenix_kit_locations IS 'pkloc_schema:2'"
  end

  test "up_statements/2 defaults target to current_version/0 and clamps above it" do
    assert Migrations.up_statements("public") == Migrations.up_statements("public", 2)
    assert Migrations.up_statements("public", 99) == Migrations.up_statements("public", 2)
  end

  test "no statement can destroy data, in either direction" do
    all = Migrations.up_statements("public") ++ Migrations.down_statements("public", 0)

    for s <- all do
      # `ON DELETE CASCADE` is core's own FK referential action, copied
      # verbatim — not a destructive statement.
      scanned =
        Regex.replace(~r/ON DELETE (CASCADE|RESTRICT|SET NULL|SET DEFAULT|NO ACTION)/i, s, "")

      refute scanned =~ ~r/\b(DROP|TRUNCATE|DELETE)\b/i, "destructive statement: #{s}"
    end
  end

  test "every CREATE INDEX and constraint is guarded" do
    for s <- Migrations.up_statements("public"), s =~ ~r/CREATE (UNIQUE )?INDEX/ do
      assert s =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/
    end

    for s <- Migrations.up_statements("public"), s =~ ~r/ADD CONSTRAINT/ do
      assert s =~ ~r/DO \$\$/ and s =~ ~r/IF NOT EXISTS/
    end
  end

  test "every pinned index name appears inside a CREATE ... IF NOT EXISTS statement" do
    stmts = Migrations.up_statements("public")

    for name <- @indexes do
      assert Enum.any?(stmts, &(&1 =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS #{name}\b/)),
             "missing guarded index #{name}"
    end

    assert length(@indexes) ==
             Enum.count(stmts, &(&1 =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/))
  end

  test "every pinned constraint name appears inside a guarded DO $$ block" do
    stmts = Migrations.up_statements("public")

    for name <- @constraints do
      assert Enum.any?(stmts, fn s -> s =~ ~r/DO \$\$/ and s =~ ~r/ADD CONSTRAINT #{name}\b/ end),
             "missing guarded constraint #{name}"
    end

    assert length(@constraints) == Enum.count(stmts, &(&1 =~ ~r/DO \$\$/))
  end

  test "the guard checks the same table and schema the constraint is added to" do
    for s <- Migrations.up_statements("tenant_a"), s =~ ~r/DO \$\$/ do
      [_, name] = Regex.run(~r/c\.conname = '([^']+)'/, s)
      [_, table] = Regex.run(~r/t\.relname = '([^']+)'/, s)

      assert s =~ "n.nspname = 'tenant_a'"
      assert s =~ "ALTER TABLE tenant_a.#{table} ADD CONSTRAINT #{name} "
    end
  end

  test "every FK cascades (the contexts rely on it for subtree and assignment cleanup)" do
    fks = Enum.filter(Migrations.up_statements("public"), &(&1 =~ "FOREIGN KEY"))

    assert length(fks) == 5
    for s <- fks, do: assert(s =~ "ON DELETE CASCADE")
  end

  test "the kind CHECK admits every app-level kind" do
    [check] =
      Enum.filter(
        Migrations.up_statements("public"),
        &(&1 =~ "phoenix_kit_location_spaces_kind_check CHECK")
      )

    for kind <- Space.kinds() do
      assert check =~ "'#{kind}'::character varying", "kind #{kind} is rejected by the DB CHECK"
    end
  end

  test "a prefix is threaded through tables, FK targets and the uuid default" do
    joined = Enum.join(Migrations.up_statements("tenant_a"), "\n")

    refute joined =~ "public."
    assert joined =~ "DEFAULT tenant_a.uuid_generate_v7()"
    assert joined =~ "REFERENCES tenant_a.phoenix_kit_locations(uuid)"
    assert joined =~ "REFERENCES tenant_a.phoenix_kit_users(uuid)"
    assert joined =~ "COMMENT ON TABLE tenant_a.phoenix_kit_locations IS 'pkloc_schema:2'"
  end

  describe "V2 (location ownership)" do
    test "adds a nullable owner column, a cascading FK to users, and an index" do
      stmts = Migrations.up_statements("public")

      assert "ALTER TABLE public.phoenix_kit_locations ADD COLUMN IF NOT EXISTS owner_uuid uuid" in stmts

      assert Enum.any?(
               stmts,
               &(&1 =~
                   "ADD CONSTRAINT phoenix_kit_locations_owner_uuid_fkey FOREIGN KEY (owner_uuid) REFERENCES public.phoenix_kit_users(uuid) ON DELETE CASCADE")
             )

      assert "CREATE INDEX IF NOT EXISTS phoenix_kit_locations_owner_uuid_index ON public.phoenix_kit_locations USING btree (owner_uuid)" in stmts
    end

    test "runs after V1 has created phoenix_kit_locations" do
      stmts = Migrations.up_statements("public")

      create =
        Enum.find_index(
          stmts,
          &(&1 =~ "CREATE TABLE IF NOT EXISTS public.phoenix_kit_locations (")
        )

      alter = Enum.find_index(stmts, &(&1 =~ "ADD COLUMN IF NOT EXISTS owner_uuid"))

      assert create < alter
    end

    test "up_statements(prefix, 1) emits only V1 and stamps pkloc_schema:1" do
      stmts = Migrations.up_statements("public", 1)

      refute Enum.join(stmts, "\n") =~ "owner_uuid"

      assert List.last(stmts) ==
               "COMMENT ON TABLE public.phoenix_kit_locations IS 'pkloc_schema:1'"

      assert Enum.count(stmts, &(&1 =~ ~r/DO \$\$/)) == length(@constraints) - 1

      assert Enum.count(stmts, &(&1 =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/)) ==
               length(@indexes) - 1
    end

    test "rolling back to V1 re-stamps the marker without dropping the column" do
      assert Migrations.down_statements("public", 1) ==
               ["COMMENT ON TABLE public.phoenix_kit_locations IS 'pkloc_schema:1'"]
    end
  end

  test "down only rewrites the marker" do
    assert Migrations.down_statements("public", 0) ==
             ["COMMENT ON TABLE public.phoenix_kit_locations IS NULL"]

    assert Migrations.down_statements("public", 1) ==
             ["COMMENT ON TABLE public.phoenix_kit_locations IS 'pkloc_schema:1'"]
  end

  test "prefix is validated before it reaches DDL" do
    assert_raise ArgumentError, fn -> Migrations.up_statements("public; DROP") end
    assert_raise ArgumentError, fn -> Migrations.down_statements("x'y", 0) end
    assert_raise ArgumentError, fn -> Migrations.migrated_version_runtime(prefix: "a b") end
  end

  # ── the drift lock ───────────────────────────────────────────────────
  #
  # Core's `ExpectedSchema` manifest is the audit authority for every
  # `owner: :locations` object, and V1 only holds together while this chain
  # reproduces what that manifest requires. A core release that adds a column
  # to an adopted table would leave this chain quietly building the older
  # shape on fresh installs while every string test above stays green.
  #
  # Resolved through `Resolver` — `mix.exs` floors core at `~> 2.0`, and the
  # manifest only ships in later releases, so "not generated" is an ordinary
  # condition here, not a failure.
  describe "core's ExpectedSchema manifest" do
    setup do
      case Resolver.resolve() do
        {:ok, manifest} -> {:ok, objects: locations_objects(manifest)}
        {:error, :not_generated} -> {:ok, objects: nil}
      end
    end

    test "every required locations-owned object is emitted by up_statements/1", ctx do
      if ctx.objects do
        # A manifest that resolved but tagged nothing `owner: :locations` (a
        # renamed owner atom upstream) would pass on an empty list.
        refute ctx.objects == []

        stmts = Migrations.up_statements("public")

        missing =
          ctx.objects
          |> Enum.filter(&(&1.presence == :required))
          |> Enum.reject(&emitted?(stmts, &1))
          |> Enum.map(& &1.id)

        assert missing == [],
               "core's manifest requires these on a fresh install, and the chain " <>
                 "does not create them:\n  " <> Enum.join(missing, "\n  ")
      end
    end

    test "no object core deliberately dropped is re-created", ctx do
      if ctx.objects do
        stmts = Migrations.up_statements("public")

        resurrected =
          ctx.objects
          |> Enum.filter(&(&1.presence == :legacy_optional and emitted?(stmts, &1)))
          |> Enum.map(& &1.id)

        assert resurrected == [],
               "chain re-creates objects core deliberately dropped:\n  " <>
                 Enum.join(resurrected, "\n  ")
      end
    end
  end

  defp locations_objects(manifest) do
    Enum.filter(manifest.objects("public"), &(&1.owner == :locations))
  end

  # The manifest's id format (`table:<t>` / `column:<t>.<c>` / `index:<name>`
  # / `constraint:<t>.<name>`) identifies the object in the emitted DDL.
  defp emitted?(stmts, %{class: :table, id: "table:" <> table}) do
    Enum.any?(stmts, &creates_table?(&1, table))
  end

  defp emitted?(stmts, %{class: :index, id: "index:" <> name}) do
    Enum.any?(stmts, &String.contains?(&1, "INDEX IF NOT EXISTS #{name} ON "))
  end

  defp emitted?(stmts, %{class: :column, id: "column:" <> rest}) do
    [table, column] = String.split(rest, ".", parts: 2)

    stmts
    |> Enum.find(&creates_table?(&1, table))
    |> declared_columns()
    |> Enum.member?(column)
  end

  defp emitted?(stmts, %{class: :constraint, id: "constraint:" <> rest}) do
    [table, name] = String.split(rest, ".", parts: 2)

    Enum.any?(stmts, fn s ->
      String.contains?(s, "ALTER TABLE public.#{table} ADD CONSTRAINT #{name} ")
    end)
  end

  defp creates_table?(statement, table) do
    String.contains?(statement, "CREATE TABLE IF NOT EXISTS public.#{table} (")
  end

  defp declared_columns(nil), do: []

  defp declared_columns(statement) do
    statement
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, ["CREATE ", "CONSTRAINT ", ")"])))
    |> Enum.map(fn line -> line |> String.split(" ", parts: 2) |> hd() |> String.trim("\"") end)
  end
end
