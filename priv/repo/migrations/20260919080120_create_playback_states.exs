# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreatePlaybackStates do
  use Ecto.Migration

  # As with the feeds migration, every object here belongs to the table this migration creates.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently column_reference_added
  # excellent_migrations:safety-assured-for-this-file check_constraint_added

  def change do
    # Progress belongs to one account and one entry, while the entry itself is shared. The unique
    # pair is what keeps a feed from ever carrying somebody else's position.
    create table(:playback_states) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :entry_id, references(:entries, on_delete: :delete_all), null: false
      add :status, :text, null: false, default: "new"
      add :position, :float, null: false, default: 0
      add :duration, :float
      add :completed_at, :utc_datetime_usec
      add :session_id, :uuid
      add :sequence, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:playback_states, [:user_id, :entry_id])
    create index(:playback_states, [:entry_id])

    create constraint(:playback_states, :valid_status,
             check: "status IN ('new', 'in_progress', 'completed')"
           )

    # A year in seconds. The bound is in the database as well as in the context, because a position
    # arrives from a browser and the column is what it finally lands in.
    create constraint(:playback_states, :valid_position,
             check: "position >= 0 AND position <= 31536000"
           )

    create constraint(:playback_states, :valid_duration,
             check: "duration IS NULL OR (duration > 0 AND duration <= 31536000)"
           )
  end
end
