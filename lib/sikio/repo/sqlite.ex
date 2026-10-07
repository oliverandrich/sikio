# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.SQLite do
  @moduledoc "The repository for SQLite. Reached through `Sikio.Repo`."

  # SQLite as dj-lite sets it up for Django: a write-ahead log so readers never wait for the
  # writer, a writer that waits up to five seconds rather than failing, and transactions that take
  # the write lock when they begin, so two never deadlock upgrading a read.
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

  # `Sikio.Repo`, spelled from this module's name. Naming it, or sharing this module's code with
  # the other repository through a module of their own, would make this file depend on others while
  # `Sikio.Repo` reads its functions when it compiles. The two repositories repeat it instead.
  @name __MODULE__ |> Module.split() |> Enum.drop(-1) |> Module.concat()

  # It runs under that name, so whoever asks for `Sikio.Repo` by name finds it, and its own
  # calls go there too.
  use Ecto.Repo, otp_app: :sikio, adapter: Ecto.Adapters.SQLite3, default_dynamic_repo: @name

  # Started through `Sikio.Repo`, the configuration set there already lies beneath the start's
  # own options. Asked for its configuration without a start, it lies above Ecto's defaults.
  # The adapter's defaults lie beneath both. Migrations and telemetry keep the names of a
  # single repository.
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

  # Turns a new file to WAL with one connection before the pool opens its own. Each of those turns
  # it too as it connects, and on an empty file they collide: SQLite refuses all but one at once
  # rather than wait, and the others log "database is locked" before they retry. A file already in
  # WAL needs no lock to stay there. A file that cannot be opened is left for the pool to report.
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
