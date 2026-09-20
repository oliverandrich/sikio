# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.CreateFeedsAndSubscriptions do
  use Ecto.Migration

  # Every index, constraint and reference below belongs to a table this migration creates, so there
  # are no rows to scan and no writers to block. The two references point at `users` and `feeds`;
  # PostgreSQL takes a brief lock on a referenced table while the new, empty table is validated,
  # and validating nothing is instant. The checks stay on for migrations that touch live tables.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently column_reference_added
  # excellent_migrations:safety-assured-for-this-file check_constraint_added

  def change do
    create table(:feeds) do
      add :url, :text, null: false
      add :title, :text, null: false
      add :kind, :string, null: false
      add :etag, :text
      add :last_modified, :text
      add :last_checked_at, :utc_datetime_usec
      add :last_error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:feeds, [:url])
    create constraint(:feeds, :valid_feed_kind, check: "kind IN ('youtube', 'podcast')")

    create table(:entries) do
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :external_id, :text, null: false
      add :title, :text, null: false
      add :media_url, :text
      add :video_id, :string
      add :published_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:entries, [:feed_id, :external_id])
    create index(:entries, [:feed_id, :published_at])

    # A feed is stored once and read by everyone who subscribes to it. This table is what makes a
    # subscription personal, and it is here rather than with the library because the refresh
    # workers ask it whether anybody still wants a feed polled.
    create table(:subscriptions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :feed_id, references(:feeds, on_delete: :delete_all), null: false
      add :paused, :boolean, default: false, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subscriptions, [:user_id, :feed_id])
    create index(:subscriptions, [:feed_id])
  end
end
