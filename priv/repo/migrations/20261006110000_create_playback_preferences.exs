# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreatePlaybackPreferences do
  use Ecto.Migration

  # A new table, so nothing here waits on rows that exist.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # How an account wants the player to behave. The users table follows the starter, so what is
  # Sikio's own sits beside it. An account without a row takes the defaults.
  def change do
    create table(:playback_preferences) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Whether the player goes on with the queue when an item ends. On, as in Castro.
      add :play_on, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:playback_preferences, [:user_id])
  end
end
