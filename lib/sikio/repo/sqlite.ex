# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.SQLite do
  @moduledoc "The repository for SQLite. Reached through `Sikio.Repo`."

  # Pragmas follow dj-lite's defaults for Django. WAL lets readers proceed during a write.
  # `busy_timeout` waits up to five seconds for a lock instead of failing.
  # `:immediate` transactions take the write lock at BEGIN, so none deadlocks upgrading a read.
  @defaults [
    journal_mode: :wal,
    synchronous: :normal,
    temp_store: :memory,
    journal_size_limit: 27_103_364,
    cache_size: 2000,
    busy_timeout: 5000,
    foreign_keys: :on,
    default_transaction_mode: :immediate,
    custom_pragmas: [mmap_size: 134_217_728]
  ]

  # `Sikio.Repo`, derived from this module's name. `Sikio.Repo` reads this module's functions
  # at compile time. Naming it here, or sharing code through a third module, adds a dependency
  # to this file. So both repositories repeat this line.
  @name __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()

  # The repository registers under that name, so name lookups for `Sikio.Repo` find it.
  # Its own calls default to that name too.
  use Ecto.Repo, otp_app: :sikio, adapter: Ecto.Adapters.SQLite3, default_dynamic_repo: @name

  # Under `:supervisor`, `Sikio.Repo` has already merged its configuration beneath the start
  # options. Under `:runtime`, the `Sikio.Repo` configuration overrides the given one.
  # `@defaults` sit beneath both. `priv` and the telemetry prefix match a single repository.
  @impl true
  def init(type, config) do
    config =
      if type == :runtime,
        do: Keyword.merge(config, Application.get_env(:sikio, @name, [])),
        else: config

    config =
      @defaults
      |> Keyword.merge(config)
      |> Keyword.put_new(:priv, "priv/repo")
      |> Keyword.put(:telemetry_prefix, [:sikio, :repo])

    if type == :supervisor, do: write_ahead(config)
    {:ok, config}
  end

  # Sets WAL on one connection before the pool opens. Each pool connection also sets it on
  # connect. On a new file, SQLite refuses concurrent switches instead of waiting.
  # The refused connections log "database is locked" and retry.
  # A file already in WAL needs no lock to keep it. The pool reports a file that cannot be opened.
  defp write_ahead(config) do
    with :wal <- config[:journal_mode],
         path when is_binary(path) and path != ":memory:" <- config[:database],
         {:ok, db} <- Exqlite.Sqlite3.open(path) do
      Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
      Exqlite.Sqlite3.close(db)
    end

    :ok
  end
end
