# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.QueueWhatIsUnderWay do
  use Ecto.Migration

  # Data only, on playback_states, which only this application writes.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  # Playing an item now puts it into the queue. What was under way before stands in neither the
  # inbox nor the queue without this, so it is queued, the last played first. The rank counts the
  # rows played later by status alone: SQLite's subquery sees the rows this update has changed
  # already. Rolling back leaves the ranks, which the earlier schema has a column for.
  def up do
    execute """
    UPDATE playback_states
    SET queue_rank = (
      SELECT count(*) FROM playback_states earlier
      WHERE earlier.user_id = playback_states.user_id
        AND earlier.status = 'in_progress'
        AND (earlier.updated_at > playback_states.updated_at
          OR (earlier.updated_at = playback_states.updated_at AND earlier.id < playback_states.id))
    )
    WHERE status = 'in_progress' AND queue_rank IS NULL
    """
  end

  def down, do: :ok
end
