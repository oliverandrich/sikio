# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.IndexEntrySearch do
  use Ecto.Migration

  @moduledoc """
  An index for the library's search, which matches any part of `search_text`.

  Both databases index the text in sequences of three characters, so a part of a word is found
  as well as a whole one. Postgres keeps a GIN index of `pg_trgm`, which the search's `LIKE`
  uses as it is. SQLite keeps an FTS5 table with the trigram tokenizer beside `entries`, filled
  from it and kept current by triggers; the search asks that table.

  The Postgres index is built concurrently, so a running instance keeps writing entries while it
  grows. That needs the migration outside a transaction.
  """

  # The extension, the full-text table and its triggers have no word in Ecto's migration DSL.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  @disable_ddl_transaction true
  @disable_migration_lock true

  @triggers [
    """
    CREATE TRIGGER entries_search_insert AFTER INSERT ON entries BEGIN
      INSERT INTO entries_search (rowid, search_text) VALUES (new.id, new.search_text);
    END
    """,
    """
    CREATE TRIGGER entries_search_delete AFTER DELETE ON entries BEGIN
      INSERT INTO entries_search (entries_search, rowid, search_text)
        VALUES ('delete', old.id, old.search_text);
    END
    """,
    """
    CREATE TRIGGER entries_search_update AFTER UPDATE OF search_text ON entries BEGIN
      INSERT INTO entries_search (entries_search, rowid, search_text)
        VALUES ('delete', old.id, old.search_text);
      INSERT INTO entries_search (rowid, search_text) VALUES (new.id, new.search_text);
    END
    """
  ]

  def up do
    if sqlite?() do
      execute """
      CREATE VIRTUAL TABLE entries_search USING fts5(
        search_text, content = 'entries', content_rowid = 'id', tokenize = 'trigram'
      )
      """

      Enum.each(@triggers, &execute/1)
      execute "INSERT INTO entries_search (entries_search) VALUES ('rebuild')"
    else
      # A trusted extension since Postgres 13: the database's owner may create it.
      execute "CREATE EXTENSION IF NOT EXISTS pg_trgm"

      create index(:entries, ["search_text gin_trgm_ops"],
               name: :entries_search_text_trigram_index,
               using: "GIN",
               concurrently: true
             )
    end
  end

  # The extension stays: something else in the database may use it.
  def down do
    if sqlite?() do
      for trigger <- ~w(entries_search_insert entries_search_delete entries_search_update) do
        execute "DROP TRIGGER IF EXISTS #{trigger}"
      end

      execute "DROP TABLE IF EXISTS entries_search"
    else
      drop index(:entries, [:search_text],
             name: :entries_search_text_trigram_index,
             concurrently: true
           )
    end
  end

  defp sqlite?, do: repo().__adapter__() == Ecto.Adapters.SQLite3
end
