# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreateBlockedEntries do
  use Ecto.Migration

  # A new table, so nothing here waits on rows that exist.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # An entry an administrator removed for everyone, by its feed and the id the feed gives it. The
  # import skips it, so a refresh does not bring it back. A removed feed takes its blocks along.
  def change do
    create table(:blocked_entries) do
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :external_id, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:blocked_entries, [:feed_id, :external_id])
  end
end
