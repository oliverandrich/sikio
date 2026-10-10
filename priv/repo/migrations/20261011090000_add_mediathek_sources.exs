# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddMediathekSources do
  use Ecto.Migration

  @moduledoc """
  Room for a fourth kind of source: the search for one topic on one channel in the German public
  broadcasters' media libraries.

  The check constraint names the kinds, so widening it is the migration. Postgres replaces the
  constraint, added unvalidated and validated in a second statement, as for PeerTube.

  SQLite cannot change a check. Its `feeds` table is rebuilt as the SQLite documentation
  describes. Entries reference feeds with `ON DELETE CASCADE`, so dropping the old table with
  foreign keys on would delete every entry. The rebuild therefore runs on one connection, with
  foreign keys off outside any transaction, and checks every reference before it commits.

  A rollback narrows the rule again and fails while a Mediathek source exists.
  """

  # Ecto's migration DSL has no words for a constraint validation or a table rebuild.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  # PRAGMA foreign_keys has no effect inside a transaction, so Ecto's own is off.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @wide "kind IN ('youtube', 'podcast', 'peertube', 'mediathek')"
  @narrow "kind IN ('youtube', 'podcast', 'peertube')"

  def up, do: widen(@narrow, @wide)
  def down, do: widen(@wide, @narrow)

  defp widen(from, to) do
    if sqlite?(), do: rebuild(from, to), else: replace_constraint(to)
  end

  defp replace_constraint(rule) do
    repo().transaction(fn ->
      repo().query!("ALTER TABLE feeds DROP CONSTRAINT valid_feed_kind")
      repo().query!("ALTER TABLE feeds ADD CONSTRAINT valid_feed_kind CHECK (#{rule}) NOT VALID")
      repo().query!("ALTER TABLE feeds VALIDATE CONSTRAINT valid_feed_kind")
    end)
  end

  # The new table is created from the stored definition, so every column keeps its type and order.
  defp rebuild(from, to) do
    repo().checkout(fn ->
      repo().query!("PRAGMA foreign_keys = OFF")

      try do
        repo().transaction(fn ->
          %{rows: [[definition]]} =
            repo().query!("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'feeds'")

          unless String.contains?(definition, from),
            do: raise("feeds does not carry the expected kind rule: #{definition}")

          repo().query!(
            definition
            |> String.replace(~s(CREATE TABLE "feeds"), ~s(CREATE TABLE "feeds_rebuilt"))
            |> String.replace(from, to)
          )

          repo().query!("INSERT INTO feeds_rebuilt SELECT * FROM feeds")
          repo().query!("DROP TABLE feeds")
          repo().query!("ALTER TABLE feeds_rebuilt RENAME TO feeds")
          repo().query!(~s|CREATE UNIQUE INDEX "feeds_url_index" ON "feeds" ("url")|)

          case repo().query!("PRAGMA foreign_key_check") do
            %{rows: []} -> :ok
            %{rows: rows} -> raise "the rebuild broke references: #{inspect(rows)}"
          end
        end)
      after
        repo().query!("PRAGMA foreign_keys = ON")
      end
    end)
  end

  defp sqlite?, do: repo().__adapter__() == Ecto.Adapters.SQLite3
end
