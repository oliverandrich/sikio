# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreateFeedAliases do
  use Ecto.Migration

  # A new table, so nothing here waits on rows that exist.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # Another URL a feed was fetched at before Sikio took it from its self URL.
  # A URL names at most one feed. A removed feed takes its aliases along.
  def change do
    create table(:feed_aliases) do
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :url, :text, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:feed_aliases, [:url])
    create index(:feed_aliases, [:feed_id])
  end
end
