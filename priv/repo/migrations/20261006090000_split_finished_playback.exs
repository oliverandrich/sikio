# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.SplitFinishedPlayback do
  use Ecto.Migration

  # Every object here belongs to playback_states, which only this application writes.
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # Only rolling back removes the queue's column, with the code that read it.
  # excellent_migrations:safety-assured-for-this-file column_removed

  # What was completed becomes heard when its place had reached 90 % of its length, the row's or
  # else the entry's, and archived otherwise. Without a length nothing says it was heard.
  @split """
  CASE
    WHEN status <> 'completed' THEN status
    WHEN position >= 0.9 * COALESCE(duration, (SELECT e.duration FROM entries e WHERE e.id = entry_id))
      THEN 'heard'
    ELSE 'archived'
  END
  """

  @statuses "status IN ('new', 'in_progress', 'heard', 'archived')"
  @old_statuses "status IN ('new', 'in_progress', 'completed')"

  def up do
    if sqlite?() do
      # SQLite cannot change a check, so the table is built again beside the old one.
      rebuild(@statuses, ", \"queue_rank\" NUMERIC", ", queue_rank", ", NULL", @split)
    else
      alter table(:playback_states) do
        add :queue_rank, :float
      end

      drop constraint(:playback_states, :valid_status)
      execute "UPDATE playback_states SET status = #{@split}"
      create constraint(:playback_states, :valid_status, check: @statuses)
    end
  end

  def down do
    finished = "CASE WHEN status IN ('heard', 'archived') THEN 'completed' ELSE status END"

    if sqlite?() do
      rebuild(@old_statuses, "", "", "", finished)
    else
      drop constraint(:playback_states, :valid_status)
      execute "UPDATE playback_states SET status = #{finished}"
      create constraint(:playback_states, :valid_status, check: @old_statuses)

      alter table(:playback_states) do
        remove :queue_rank
      end
    end
  end

  # The table as the first migration made it, with `statuses` as its check and `extra` columns,
  # filled from the old one with `status` mapped and `values` for what the old one lacks.
  defp rebuild(statuses, extra, columns, values, status) do
    execute """
    CREATE TABLE "playback_states_next" ("id" INTEGER PRIMARY KEY AUTOINCREMENT,
      "user_id" INTEGER NOT NULL CONSTRAINT "playback_states_user_id_fkey" REFERENCES "users"("id") ON DELETE CASCADE,
      "entry_id" INTEGER NOT NULL CONSTRAINT "playback_states_entry_id_fkey" REFERENCES "entries"("id") ON DELETE CASCADE,
      "status" TEXT DEFAULT 'new' NOT NULL CONSTRAINT valid_status CHECK (#{statuses}),
      "position" NUMERIC DEFAULT 0 NOT NULL CONSTRAINT valid_position CHECK (position >= 0 AND position <= 31536000),
      "duration" NUMERIC CONSTRAINT valid_duration CHECK (duration IS NULL OR (duration > 0 AND duration <= 31536000)),
      "completed_at" TEXT, "session_id" TEXT, "sequence" INTEGER DEFAULT 0 NOT NULL,
      "inserted_at" TEXT NOT NULL, "updated_at" TEXT NOT NULL#{extra})
    """

    shared =
      "id, user_id, entry_id, position, duration, completed_at, session_id, sequence, inserted_at, updated_at"

    execute """
    INSERT INTO playback_states_next (#{shared}, status#{columns})
    SELECT #{shared}, #{status}#{values} FROM playback_states
    """

    execute "DROP TABLE playback_states"
    execute "ALTER TABLE playback_states_next RENAME TO playback_states"
    create unique_index(:playback_states, [:user_id, :entry_id])
    create index(:playback_states, [:entry_id])
  end

  defp sqlite?, do: repo().__adapter__() == Ecto.Adapters.SQLite3
end
