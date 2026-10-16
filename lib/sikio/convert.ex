# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Convert do
  @moduledoc """
  Copies every row between a PostgreSQL and a SQLite database at the same migration version.

  This module addresses `Sikio.Repo.Postgres` and `Sikio.Repo.SQLite` directly, since it needs
  both at once. Everything else calls `Sikio.Repo`.

  Column types come from PostgreSQL in either direction. SQLite declares datetimes, UUIDs and
  strings as TEXT and booleans as INTEGER, so its own declarations cannot tell them apart.
  Each value is loaded with the source adapter and dumped with the target adapter.

  Tables are copied in foreign key order. Ecto creates references that are not deferrable.
  """

  alias Ecto.Adapters.SQL
  alias Sikio.Repo.Postgres
  alias Sikio.Repo.SQLite

  # Oban's tables differ between its engines, and its cron entries recreate the jobs.
  # Challenges expire within minutes. Each target already holds its migration versions.
  @skipped ~w(challenges schema_migrations)
  @skipped_prefixes ["oban_"]

  # SQLite keeps the library search in an FTS5 table that its triggers fill.
  @sqlite_only_prefixes ["entries_search", "sqlite_"]

  # Rows per INSERT. SQLite allows 32766 parameters in one statement.
  @batch 500

  @doc """
  Copies all rows from `source` into `target`, each given as `{repo_module, repo}`.

  `repo` is a name or pid accepted by `put_dynamic_repo/1`. One side must be PostgreSQL and the
  other SQLite, both migrated to the same versions. Every copied table in `target` must be empty.
  The copy runs in one transaction on `target`. `source` is only read.
  """
  def copy({source_module, _} = source, {target_module, _} = target)
      when {source_module, target_module} in [{Postgres, SQLite}, {SQLite, Postgres}] do
    with_repos([source, target], fn ->
      with :ok <- same_migrations(source_module, target_module),
           {:ok, tables} <- tables(),
           :ok <- same_tables(tables),
           :ok <- empty(target_module, tables) do
        transfer(source_module, target_module, tables)
      end
    end)
  end

  defp with_repos(pairs, fun) do
    previous = for {module, repo} <- pairs, do: {module, module.put_dynamic_repo(repo)}

    try do
      fun.()
    after
      Enum.each(previous, fn {module, repo} -> module.put_dynamic_repo(repo) end)
    end
  end

  defp same_migrations(source, target) do
    if versions(source) == versions(target), do: :ok, else: {:error, :migrations_differ}
  end

  defp versions(module),
    do: rows(module, "SELECT version FROM schema_migrations ORDER BY version")

  # Returns `[{table, [{column, type}]}]` in foreign key order, read from PostgreSQL's catalogue.
  defp tables do
    columns =
      Postgres
      |> rows("""
      SELECT c.table_name, c.column_name, c.udt_name, c.datetime_precision
      FROM information_schema.columns c
      JOIN information_schema.tables t
        ON t.table_schema = c.table_schema AND t.table_name = c.table_name
      WHERE c.table_schema = current_schema() AND t.table_type = 'BASE TABLE'
      ORDER BY c.table_name, c.ordinal_position
      """)
      |> Enum.reject(fn [table | _] -> skipped?(table) end)

    with {:ok, typed} <- typed(columns) do
      grouped = Enum.group_by(typed, &elem(&1, 0), &elem(&1, 1))
      ordered(grouped, references())
    end
  end

  defp typed(columns) do
    case Enum.find(columns, fn [_table, _column, udt, precision] -> !type(udt, precision) end) do
      nil ->
        {:ok,
         for(
           [table, column, udt, precision] <- columns,
           do: {table, {column, type(udt, precision)}}
         )}

      [table, column, udt, _precision] ->
        {:error, {:unknown_type, table, column, udt}}
    end
  end

  @types %{
    "int2" => :integer,
    "int4" => :integer,
    "int8" => :integer,
    "text" => :string,
    "varchar" => :string,
    "bool" => :boolean,
    "float4" => :float,
    "float8" => :float,
    "numeric" => :decimal,
    "uuid" => :binary_id,
    "bytea" => :binary,
    "jsonb" => :map,
    "_jsonb" => {:array, :map},
    "date" => :date
  }

  defp type(udt, 0) when udt in ~w(timestamp timestamptz), do: :utc_datetime
  defp type(udt, _precision) when udt in ~w(timestamp timestamptz), do: :utc_datetime_usec
  defp type(udt, _precision), do: Map.get(@types, udt)

  # A table referencing itself counts as a cycle, since its rows are read in no fixed order.
  defp references do
    Postgres
    |> rows("""
    SELECT child.relname, parent.relname
    FROM pg_constraint fk
    JOIN pg_class child ON child.oid = fk.conrelid
    JOIN pg_class parent ON parent.oid = fk.confrelid
    JOIN pg_namespace ns ON ns.oid = child.relnamespace
    WHERE fk.contype = 'f' AND ns.nspname = current_schema()
    """)
    |> Enum.group_by(&hd/1, &List.last/1)
  end

  # Places each table after the tables it references. A cycle leaves tables unplaced.
  # Placed tables leave `tables`, so a reference to a key no longer present is satisfied.
  defp ordered(tables, references, placed \\ []) do
    ready =
      tables
      |> Map.keys()
      |> Enum.filter(fn table ->
        Enum.all?(Map.get(references, table, []), &(not Map.has_key?(tables, &1)))
      end)
      |> Enum.sort()

    case ready do
      [] when tables == %{} ->
        {:ok, placed}

      [] ->
        {:error, {:reference_cycle, tables |> Map.keys() |> Enum.sort()}}

      _ ->
        ordered(Map.drop(tables, ready), references, placed ++ Enum.map(ready, &{&1, tables[&1]}))
    end
  end

  # Tables and columns must match on both sides, apart from SQLite's search index.
  defp same_tables(tables) do
    expected =
      Map.new(tables, fn {table, columns} -> {table, Enum.map(columns, &elem(&1, 0))} end)

    actual =
      for [table] <- rows(SQLite, "SELECT name FROM sqlite_master WHERE type = 'table'"),
          not skipped?(table),
          not String.starts_with?(table, @sqlite_only_prefixes),
          into: %{} do
        {table, Enum.map(rows(SQLite, ~s|PRAGMA table_info("#{table}")|), &Enum.at(&1, 1))}
      end

    differing =
      for table <- Enum.uniq(Map.keys(expected) ++ Map.keys(actual)),
          Enum.sort(Map.get(expected, table, [])) != Enum.sort(Map.get(actual, table, [])),
          do: table

    if differing == [], do: :ok, else: {:error, {:tables_differ, Enum.sort(differing)}}
  end

  defp empty(target, tables) do
    case Enum.find(tables, fn {table, _} ->
           rows(target, ~s|SELECT 1 FROM "#{table}" LIMIT 1|) != []
         end) do
      nil -> :ok
      {table, _} -> {:error, {:not_empty, table}}
    end
  end

  defp transfer(source, target, tables) do
    result =
      target.transaction(fn ->
        read(source, fn -> Enum.each(tables, &copy_table(source, target, &1)) end)
        if target == Postgres, do: continue_sequences()
      end)

    case result do
      {:ok, _} -> :ok
      error -> error
    end
  end

  # SQLite's `:immediate` default would take the write lock on a source that is only read.
  defp read(SQLite, fun), do: SQLite.transaction(fun, mode: :deferred)

  # One snapshot for all tables, so a stray writer cannot split a parent from its child rows.
  defp read(Postgres, fun) do
    Postgres.transaction(fn ->
      Postgres.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
      fun.()
    end)
  end

  defp copy_table(source, target, {table, columns}) do
    names = Enum.map_join(columns, ", ", fn {column, _} -> ~s|"#{column}"| end)
    converters = Enum.map(columns, &converter(source, target, table, &1))
    full = insert_sql(target, table, names, length(columns), @batch)

    source.get_dynamic_repo()
    |> SQL.stream(~s|SELECT #{names} FROM "#{table}"|, [], max_rows: @batch)
    |> Enum.each(fn
      %{rows: []} ->
        :ok

      %{rows: batch} ->
        values =
          Enum.flat_map(batch, &Enum.zip_with(&1, converters, fn raw, fun -> fun.(raw) end))

        count = length(batch)

        sql =
          if count == @batch,
            do: full,
            else: insert_sql(target, table, names, length(columns), count)

        target.query!(sql, values)
    end)
  end

  # Loads a value with the source adapter and dumps it with the target adapter.
  defp converter(source, target, table, {column, type}) do
    {loader, dumper} = {source.__adapter__(), target.__adapter__()}

    fn raw ->
      with {:ok, value} <- Ecto.Type.adapter_load(loader, type, raw),
           {:ok, dumped} <- Ecto.Type.adapter_dump(dumper, type, value) do
        dumped
      else
        _ -> target.rollback({:unconvertible, table, column})
      end
    end
  end

  defp insert_sql(target, table, names, width, count) do
    rows =
      Enum.map_join(0..(count - 1), ", ", fn row ->
        "(" <> Enum.map_join(1..width, ", ", &placeholder(target, row * width + &1)) <> ")"
      end)

    ~s|INSERT INTO "#{table}" (#{names}) VALUES #{rows}|
  end

  defp placeholder(Postgres, index), do: "$#{index}"
  defp placeholder(SQLite, _index), do: "?"

  # Explicit ids leave each sequence at its start. Each continues after its column's highest id.
  defp continue_sequences do
    for [table, column] <-
          rows(Postgres, """
          SELECT table_name, column_name FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND (column_default LIKE 'nextval(%' OR is_identity = 'YES')
          """) do
      Postgres.query!(
        ~s|SELECT setval(pg_get_serial_sequence($1, $2), COALESCE(MAX("#{column}"), 0) + 1, false) FROM "#{table}"|,
        [table, column]
      )
    end
  end

  @doc "Whether the conversion leaves `table` out. Its rows expire or are rebuilt."
  def skipped?(table), do: table in @skipped or String.starts_with?(table, @skipped_prefixes)

  defp rows(module, sql), do: module.query!(sql).rows
end
