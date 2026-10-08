# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreateSavedEntries do
  use Ecto.Migration

  # A new table, so nothing here waits on rows that exist.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # An entry an account added singly, without following its source. The entry stays shared
  # under its feed, which is not polled for it.
  def change do
    create table(:saved_entries) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :entry_id, references(:entries, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:saved_entries, [:user_id, :entry_id])
    create index(:saved_entries, [:entry_id])
  end
end
