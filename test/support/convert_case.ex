# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ConvertCase do
  @moduledoc """
  Creates a PostgreSQL database and a SQLite file per test, for the conversion between them.

  Tests using it need both databases, so they are tagged `:postgres` and run in that pass.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL
  alias Sikio.DataCase
  alias Sikio.Repo

  using do
    quote do
      use ExUnit.Case, async: false

      import Sikio.ConvertCase

      @moduletag :postgres
    end
  end

  setup do
    # Each migration run loads the migration files again, which redefines their modules.
    conflicts = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, conflicts) end)

    previous = Repo.put_dynamic_repo(Repo)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    :ok
  end

  @doc "Creates an empty PostgreSQL database and returns its options, with `:url`, for `start!/2`."
  def postgres_config! do
    config =
      Keyword.merge(Repo.config(),
        database: "sikio_convert_#{DataCase.unique()}",
        pool: DBConnection.ConnectionPool,
        pool_size: 2
      )

    :ok = Ecto.Adapters.Postgres.storage_up(config)
    on_exit(fn -> Ecto.Adapters.Postgres.storage_down(config) end)
    Keyword.put(config, :url, url(config))
  end

  @doc "Returns the path of a SQLite file that does not exist yet. The test removes it afterwards."
  def sqlite_path! do
    path = Path.join(System.tmp_dir!(), "sikio_convert_#{DataCase.unique()}.db")
    on_exit(fn -> Enum.each(files(path), &File.rm/1) end)
    path
  end

  @doc "The files SQLite keeps for the database at `path`."
  def files(path), do: [path, path <> "-wal", path <> "-shm"]

  @doc "Starts `module` on `config` without a name and returns `{module, pid}`."
  def start!(module, config) do
    {:ok, repo} = module.start_link(Keyword.merge(config, name: nil, pool_size: 2))
    {module, repo}
  end

  @doc "Migrates the repository to the newest version and returns it."
  def migrate!({module, repo} = started) do
    path = Ecto.Migrator.migrations_path(Repo)
    opts = [all: true, dynamic_repo: repo, log: false, log_migrations_sql: false]
    Ecto.Migrator.run(module, path, :up, opts)
    started
  end

  @doc "A migrated PostgreSQL database, as `{Sikio.Repo.Postgres, pid}`."
  def postgres!, do: Repo.Postgres |> start!(postgres_config!()) |> migrate!()

  @doc "A migrated SQLite file, as `{Sikio.Repo.SQLite, pid}`."
  def sqlite!, do: Repo.SQLite |> start!(database: sqlite_path!()) |> migrate!()

  @doc "Runs `sql` on a repository started by `start!/2`."
  def query!({_module, repo}, sql, params \\ []), do: SQL.query!(repo, sql, params)

  defp url(config) do
    password = URI.encode_www_form(config[:password] || "")
    port = config[:port] || 5432
    "ecto://#{config[:username]}:#{password}@#{config[:hostname]}:#{port}/#{config[:database]}"
  end
end
