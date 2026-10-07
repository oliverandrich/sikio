# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.MigrationCase do
  @moduledoc """
  A migration watched on a database of its own, made for the test and dropped after it.

  The sandbox starts with every migration already run, so it cannot show one at work. Here the
  test migrates to a version, writes what the data looked like then, migrates on and reads what
  became of it. It runs on whichever database the build serves.
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

    # Each test loads the migration files again, which redefines their modules on purpose.
    conflicts = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)
    on_exit(fn -> Code.put_compiler_option(:ignore_module_conflict, conflicts) end)

    :ok = Repo.__adapter__().storage_up(config)
    {:ok, repo} = Repo.start_link(config)
    previous = Repo.put_dynamic_repo(repo)

    # The repo ends with the test process it is linked to; what is left is the database.
    on_exit(fn -> Repo.__adapter__().storage_down(config) end)
    on_exit(fn -> Repo.put_dynamic_repo(previous) end)
    %{repo: repo}
  end

  @doc "Migrates the test's database up to `version`, or down to just after it."
  def migrate(repo, direction, version) do
    path = Ecto.Migrator.migrations_path(Repo)
    opts = [dynamic_repo: repo, log: false, log_migrations_sql: false]

    case direction do
      :up -> Ecto.Migrator.run(Repo, path, :up, [to: version] ++ opts)
      :down -> Ecto.Migrator.run(Repo, path, :down, [to: version + 1] ++ opts)
    end
  end

  @doc """
  Writes an entry as its table stood at the version migrated to, and answers a map of its id.

  The schema names the table's columns as they are now. One added later would refuse the row.
  """
  def entry!(feed_id, attrs) do
    now = DateTime.utc_now()
    row = Map.merge(%{feed_id: feed_id, inserted_at: now, updated_at: now}, Map.new(attrs))
    {1, [%{id: id}]} = Repo.insert_all("entries", [row], returning: [:id])
    %{id: id}
  end

  @doc "The error the build's database raises when it refuses a statement."
  def database_error do
    case Application.fetch_env!(:sikio, :database) do
      :sqlite -> Exqlite.Error
      :postgres -> Postgrex.Error
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
