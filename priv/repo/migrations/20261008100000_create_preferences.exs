# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreatePreferences do
  use Ecto.Migration

  # The table holds one small row per account, and only this application reads it.
  # excellent_migrations:safety-assured-for-this-file table_dropped
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # Ecto's migration DSL has no word for copying rows between tables.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  # The preferences grow beyond the player: the start page and the language join Play on.
  # A new table instead of a rename gives PostgreSQL the index and key names of a fresh install.
  # A start tag that is deleted leaves the start page on `start_view`.
  # A nil `locale` follows the browser's `Accept-Language`.
  def up do
    create table(:preferences) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :play_on, :boolean, null: false, default: true
      add :start_view, :string, null: false, default: "queue"
      add :start_tag_id, references(:tags, on_delete: :nilify_all)
      add :locale, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:preferences, [:user_id])

    execute """
    INSERT INTO preferences (user_id, play_on, inserted_at, updated_at)
    SELECT user_id, play_on, inserted_at, updated_at FROM playback_preferences
    """

    drop table(:playback_preferences)
  end

  def down do
    create table(:playback_preferences) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :play_on, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:playback_preferences, [:user_id])

    execute """
    INSERT INTO playback_preferences (user_id, play_on, inserted_at, updated_at)
    SELECT user_id, play_on, inserted_at, updated_at FROM preferences
    """

    drop table(:preferences)
  end
end
