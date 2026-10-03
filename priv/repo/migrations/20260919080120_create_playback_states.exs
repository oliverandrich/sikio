# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreatePlaybackStates do
  use Ecto.Migration

  # As with the feeds migration, every object here belongs to the table this migration creates.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently column_reference_added
  # excellent_migrations:safety-assured-for-this-file check_constraint_added

  # A year in seconds. The bound is in the database as well as in the context, because a position
  # arrives from a browser and the column is what it finally lands in.
  @checks [
    status: {:valid_status, "status IN ('new', 'in_progress', 'completed')"},
    position: {:valid_position, "position >= 0 AND position <= 31536000"},
    duration: {:valid_duration, "duration IS NULL OR (duration > 0 AND duration <= 31536000)"}
  ]

  # SQLite sets a check only where the table is created, Postgres beside it.
  def change do
    sqlite? = repo().__adapter__() == Ecto.Adapters.SQLite3
    check = fn column -> if sqlite?, do: [check: sqlite_check(column)], else: [] end

    # Progress belongs to one account and one entry, while the entry itself is shared. The unique
    # pair is what keeps a feed from ever carrying somebody else's position.
    create table(:playback_states) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :entry_id, references(:entries, on_delete: :delete_all), null: false
      add :status, :text, [null: false, default: "new"] ++ check.(:status)
      add :position, :float, [null: false, default: 0] ++ check.(:position)
      add :duration, :float, check.(:duration)
      add :completed_at, :utc_datetime_usec
      add :session_id, :uuid
      add :sequence, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:playback_states, [:user_id, :entry_id])
    create index(:playback_states, [:entry_id])

    unless sqlite? do
      for {_column, {name, expr}} <- @checks do
        create constraint(:playback_states, name, check: expr)
      end
    end
  end

  defp sqlite_check(column) do
    {name, expr} = Keyword.fetch!(@checks, column)
    %{name: Atom.to_string(name), expr: expr}
  end
end
