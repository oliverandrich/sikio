# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreateTags do
  use Ecto.Migration

  @moduledoc """
  An account's own tags and the subscriptions that carry them.

  A tag is unique within its account by its key, the name in lowercase, so "Must view" and
  "must view" are one tag. The key is written by the application, because SQLite's `lower()`
  folds ASCII only. Both tables are new, so their indexes and references lock nothing.
  """

  # excellent_migrations:safety-assured-for-this-file index_not_concurrently column_reference_added

  def change do
    create table(:tags) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, size: 40, null: false
      add :key, :string, size: 40, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tags, [:user_id, :key])

    create table(:subscription_tags) do
      add :subscription_id, references(:subscriptions, on_delete: :delete_all), null: false
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
    end

    create unique_index(:subscription_tags, [:subscription_id, :tag_id])
    create index(:subscription_tags, [:tag_id])
  end
end
