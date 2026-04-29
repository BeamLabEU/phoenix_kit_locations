defmodule PhoenixKitLocations.Test.Repo.Migrations.SetupPhoenixKit do
  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pgcrypto")

    execute("""
    CREATE OR REPLACE FUNCTION uuid_generate_v7()
    RETURNS uuid AS $$
    DECLARE
      unix_ts_ms bytea;
      uuid_bytes bytea;
    BEGIN
      unix_ts_ms := substring(int8send(floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3);
      uuid_bytes := unix_ts_ms || gen_random_bytes(10);
      uuid_bytes := set_byte(uuid_bytes, 6, (get_byte(uuid_bytes, 6) & 15) | 112);
      uuid_bytes := set_byte(uuid_bytes, 8, (get_byte(uuid_bytes, 8) & 63) | 128);
      RETURN encode(uuid_bytes, 'hex')::uuid;
    END
    $$ LANGUAGE plpgsql VOLATILE;
    """)

    # Location Types
    create table(:phoenix_kit_location_types, primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:status, :string, default: "active", size: 20)
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:phoenix_kit_location_types, [:status]))

    # Locations
    create table(:phoenix_kit_locations, primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))
      add(:name, :string, null: false, size: 255)
      add(:description, :text)
      add(:public_notes, :text)
      add(:address_line_1, :string, size: 500)
      add(:address_line_2, :string, size: 500)
      add(:city, :string, size: 255)
      add(:state, :string, size: 255)
      add(:postal_code, :string, size: 20)
      add(:country, :string, size: 255)
      add(:phone, :string, size: 50)
      add(:email, :string, size: 255)
      add(:website, :string, size: 500)
      add(:notes, :text)
      add(:status, :string, default: "active", size: 20)
      add(:features, :map, default: %{})
      add(:data, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:phoenix_kit_locations, [:status]))

    # Location ↔ Type join
    create table(:phoenix_kit_location_type_assignments, primary_key: false) do
      add(:uuid, :uuid, primary_key: true, default: fragment("uuid_generate_v7()"))

      add(
        :location_uuid,
        references(:phoenix_kit_locations,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all
        ),
        null: false
      )

      add(
        :location_type_uuid,
        references(:phoenix_kit_location_types,
          column: :uuid,
          type: :uuid,
          on_delete: :delete_all
        ),
        null: false
      )

      timestamps(type: :utc_datetime)
    end

    create(
      unique_index(:phoenix_kit_location_type_assignments, [
        :location_uuid,
        :location_type_uuid
      ])
    )

    create(index(:phoenix_kit_location_type_assignments, [:location_uuid]))
    create(index(:phoenix_kit_location_type_assignments, [:location_type_uuid]))

    # Settings table — mirrors core's real schema so PhoenixKit.Settings
    # callers (e.g. Multilang's `languages_enabled` lookup at LV mount)
    # hit a real (empty) table instead of logging "relation does not
    # exist" on every test. Column shape per workspace AGENTS.md:921.
    create_if_not_exists table(:phoenix_kit_settings, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:key, :string, null: false, size: 255)
      add(:value, :string)
      add(:value_json, :map)
      add(:module, :string, size: 50)
      add(:date_added, :utc_datetime, default: fragment("now()"))
      add(:date_updated, :utc_datetime, default: fragment("now()"))
    end

    create_if_not_exists(unique_index(:phoenix_kit_settings, [:key]))

    # Activity feed table (normally created by PhoenixKit V90 migration).
    # Uses binary_id (not uuid_generate_v7()) because the Ecto schema
    # supplies the UUIDv7 — the DB column only needs to hold 16 bytes.
    create_if_not_exists table(:phoenix_kit_activities, primary_key: false) do
      add(:uuid, :binary_id, primary_key: true)
      add(:action, :string, null: false, size: 100)
      add(:module, :string, size: 50)
      add(:mode, :string, size: 20)
      add(:actor_uuid, :binary_id)
      add(:resource_type, :string, size: 50)
      add(:resource_uuid, :binary_id)
      add(:target_uuid, :binary_id)
      add(:metadata, :map, default: %{})
      add(:inserted_at, :utc_datetime, null: false, default: fragment("now()"))
    end

    create_if_not_exists(index(:phoenix_kit_activities, [:module]))
    create_if_not_exists(index(:phoenix_kit_activities, [:action]))
    create_if_not_exists(index(:phoenix_kit_activities, [:actor_uuid]))
    create_if_not_exists(index(:phoenix_kit_activities, [:inserted_at]))
  end

  def down do
    drop_if_exists(table(:phoenix_kit_activities))
    drop_if_exists(table(:phoenix_kit_settings))
    drop_if_exists(table(:phoenix_kit_location_type_assignments))
    drop_if_exists(table(:phoenix_kit_locations))
    drop_if_exists(table(:phoenix_kit_location_types))
  end
end
