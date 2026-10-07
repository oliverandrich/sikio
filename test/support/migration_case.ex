# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.MigrationCase do
  @moduledoc """
  Runs migrations on a separate database, created for the test and dropped afterwards.

  The sandbox database is fully migrated, so it cannot exercise a single migration.
  A test migrates to a version, inserts rows in that version's shape, migrates on and reads them.
  It runs on the configured database, SQLite or PostgreSQL.
  """
  use ExUnit.CaseTemplate

  alias Sikio.Repo

  using do
    quote do
      use ExUnit.Case, async: false

      import Ecto.Query
      import Sikio.MigrationCase

      alias Sikio.Repo
    end
  end

  setup do
    name =
      case Application.fetch_env!(:sikio, :database) do
        :sqlite -> Path.join(System.tmp_dir!(), "sikio_migration_#{unique()}.db")
        :postgres -> "sikio_migration_#{unique()}"
      end

    # Migrations hold one connection for their lock and use another.
    config =
      Keyword.merge(Repo.config(),
        name: nil,
        database: name,
        pool: DBConnection.ConnectionPool,
        pool_size: 2
      )

    # Each test loads the migration files again, which redefines their modules.
    conflicts = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, conflicts) end)

    :ok = Repo.__adapter__().storage_up(config)
    {:ok, repo} = Repo.start_link(config)
    previous = Repo.put_dynamic_repo(repo)

    # The repo is linked to the test process and stops with it. Only the database needs removal.
    on_exit(fn -> Repo.__adapter__().storage_down(config) end)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    %{repo: repo}
  end

  @doc "Migrates the test database up to `version`, or down until `version` is the newest."
  def migrate(repo, direction, version) do
    path = Ecto.Migrator.migrations_path(Repo)
    opts = [dynamic_repo: repo, log: false, log_migrations_sql: false]

    case direction do
      :up -> Ecto.Migrator.run(Repo, path, :up, [to: version] ++ opts)
      :down -> Ecto.Migrator.run(Repo, path, :down, [to: version + 1] ++ opts)
    end
  end

  @doc """
  Inserts an `entries` row in the table's shape at the migrated version. Returns `%{id: id}`.

  The row bypasses the schema. The schema lists current columns, which would fail the insert.
  """
  def entry!(feed_id, attrs) do
    now = DateTime.utc_now()
    row = Map.merge(%{feed_id: feed_id, inserted_at: now, updated_at: now}, Map.new(attrs))
    {1, [%{id: id}]} = Repo.insert_all("entries", [row], returning: [:id])
    %{id: id}
  end

  @doc "Returns the exception module the configured database raises for a rejected statement."
  def database_error do
    case Application.fetch_env!(:sikio, :database) do
      :sqlite -> Exqlite.Error
      :postgres -> Postgrex.Error
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
