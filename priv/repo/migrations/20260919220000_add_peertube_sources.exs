defmodule Sikio.Repo.Migrations.AddPeertubeSources do
  use Ecto.Migration

  @moduledoc """
  Room for a third kind of source, whose videos are played by the instance that holds them.

  The check constraint named the two kinds the application knew, so widening it is the migration.
  The new one is added unvalidated and validated in a second statement, which is the shape that
  keeps the row scan out of the lock that blocks writers.

  Ecto runs a migration inside a transaction, so here the lock is held until it commits and the
  split buys nothing yet. It is written this way because the shape is what matters if the
  transaction is ever disabled, and because a validated add on a live table is the thing the
  project's own checks refuse.

  No stored row can fail the new rule, because it permits everything the old one did.

  `embed_url` is nullable, because only a PeerTube entry has one.
  """

  # `VALIDATE CONSTRAINT` is the statement that makes the two-step safe, and Ecto's migration
  # DSL has no word for it. Removing a column is what reversing this migration means.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed column_removed

  @kinds "kind IN ('youtube', 'podcast', 'peertube')"

  def up do
    drop constraint(:feeds, :valid_feed_kind)
    create constraint(:feeds, :valid_feed_kind, check: @kinds, validate: false)
    execute "ALTER TABLE feeds VALIDATE CONSTRAINT valid_feed_kind"

    alter table(:entries) do
      add :embed_url, :string, size: 2048
    end
  end

  def down do
    alter table(:entries) do
      remove :embed_url
    end

    drop constraint(:feeds, :valid_feed_kind)

    create constraint(:feeds, :valid_feed_kind,
             check: "kind IN ('youtube', 'podcast')",
             validate: false
           )

    execute "ALTER TABLE feeds VALIDATE CONSTRAINT valid_feed_kind"
  end
end
