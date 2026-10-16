# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ReleaseConvertTest do
  @moduledoc false
  use Sikio.ConvertCase

  alias Sikio.Release
  alias Sikio.Repo

  setup do
    %{path: sqlite_path!()}
  end

  test "converts PostgreSQL into a new SQLite file and back into an empty database", c do
    assert :ok = Release.convert_to_sqlite(c.path, migrated_source())
    assert File.exists?(c.path)
    assert :ok = Release.convert_to_postgres(postgres_config!()[:url], database: c.path)
  end

  test "never writes over an existing file", c do
    File.write!(c.path, "kept")
    assert {:error, :target_exists} = Release.convert_to_sqlite(c.path, [])
    assert File.read!(c.path) == "kept"
  end

  # SQLite would read a leftover WAL file as part of the new database.
  test "never writes beside a leftover write-ahead log", c do
    File.write!(c.path <> "-wal", "kept")
    assert {:error, :target_exists} = Release.convert_to_sqlite(c.path, [])
    assert File.read!(c.path <> "-wal") == "kept"
    refute File.exists?(c.path)
  end

  test "asks for an absolute path" do
    assert {:error, :relative_path} = Release.convert_to_sqlite("sikio.db", [])
    refute File.exists?("sikio.db")
  end

  test "removes the new file when the conversion stops", c do
    source = migrated_source()
    query!(start!(Repo.Postgres, source), "CREATE TABLE stray (id integer)")

    assert {:error, {:tables_differ, ["stray"]}} = Release.convert_to_sqlite(c.path, source)
    refute File.exists?(c.path)
  end

  test "removes the new file when the conversion raises", c do
    source = Keyword.put(Repo.config(), :database, "sikio_convert_missing")
    assert_raise DBConnection.ConnectionError, fn -> Release.convert_to_sqlite(c.path, source) end
    refute File.exists?(c.path)
  end

  test "leaves a PostgreSQL target that holds tables unmigrated", c do
    target = postgres_config!()
    repo = start!(Repo.Postgres, target)
    query!(repo, "CREATE TABLE stray (id integer)")

    assert :ok = Release.convert_to_sqlite(c.path, migrated_source())

    assert {:error, :target_not_empty} =
             Release.convert_to_postgres(target[:url], database: c.path)

    assert %{rows: [[nil]]} = query!(repo, "SELECT to_regclass('schema_migrations')")
  end

  defp migrated_source do
    config = postgres_config!()
    Repo.Postgres |> start!(config) |> migrate!()
    config
  end
end
