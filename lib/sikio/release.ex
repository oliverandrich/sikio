# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Release do
  @moduledoc """
  Commands an operator runs against an assembled release.

  Each starts only the repositories it needs, not the application. One can run beside a server
  without binding a second port or starting Oban.
  """
  alias Ecto.Adapters.SQL
  alias Ithibati.Identity.Instance
  alias Sikio.Claim
  alias Sikio.Convert
  alias Sikio.Repo.Postgres
  alias Sikio.Repo.SQLite

  @app :sikio

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Issues a setup code for claiming this instance and prints it to stdout once.

  Only its digest is stored. A lost code cannot be shown again; issue a new one instead.
  Issuing a new code invalidates the previous one. This function writes it nowhere else.

  Returns `{:error, :already_claimed}` without a code when an account exists.
  Printing a code nobody can use would look like success.
  """
  def setup_code do
    case issue() do
      {:ok, code} ->
        IO.puts("Enter this once, on the site, to claim the instance. It is shown only here.")
        IO.puts(code)
        :ok

      {:error, :already_claimed} = error ->
        IO.puts("This instance is already claimed. No code was issued and none is needed.")
        error

      {:error, reason} = error ->
        IO.puts("No code was issued: #{inspect(reason)}")
        error
    end
  end

  @doc "Runs `setup_code/0` and halts with exit status 1 on error, for shell scripts."
  def setup_code! do
    case setup_code() do
      :ok -> :ok
      _error -> System.halt(1)
    end
  end

  # `eval` loads the configuration but starts no application, so the start-up check does not run.
  # Without this call, Ithibati returns `:claim_is_open`, which does not name the key to change.
  defp issue do
    Claim.verify!()
    with_repo(&Instance.issue_code/0)
  end

  def rollback(repo, version) do
    Application.load(@app)
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  @doc """
  Copies the configured PostgreSQL database into a new SQLite file at the absolute `path`.

  The instance must be stopped. An existing file is never written to.
  The new file is removed when the conversion stops.
  """
  def convert_to_sqlite(path, source \\ repo_config()) do
    # SQLite would read a leftover write-ahead log as part of the new file.
    files = [path, path <> "-wal", path <> "-shm"]

    cond do
      Path.type(path) != :absolute ->
        {:error, :relative_path}

      Enum.any?(files, &File.exists?/1) ->
        {:error, :target_exists}

      true ->
        removing_on_failure(files, fn ->
          convert({Postgres, source}, {SQLite, [database: path]})
        end)
    end
  end

  # The operator names the path on the command line. The removal runs only on files the
  # conversion created, since `convert_to_sqlite/2` refuses a path where any of them exists.
  # sobelow_skip ["Traversal.FileModule"]
  defp removing_on_failure(files, fun) do
    result = fun.()
    if result != :ok, do: Enum.each(files, &File.rm/1)
    result
  rescue
    exception ->
      Enum.each(files, &File.rm/1)
      reraise exception, __STACKTRACE__
  end

  @doc """
  Copies the configured SQLite database into the existing PostgreSQL database at `url`.

  The instance must be stopped. The target must hold no tables. It is migrated before the copy.
  `ECTO_IPV6` applies to the target as it does to `DATABASE_URL`.
  """
  def convert_to_postgres(url, source \\ repo_config()),
    do: convert({SQLite, source}, {Postgres, [url: url] ++ ipv6()})

  defp ipv6,
    do: if(System.get_env("ECTO_IPV6") in ~w(true 1), do: [socket_options: [:inet6]], else: [])

  @doc "Runs `convert_to_sqlite/1` on `TARGET_DATABASE_PATH` and halts with status 1 on error."
  def convert_to_sqlite!, do: convert!(:postgres, "TARGET_DATABASE_PATH", &convert_to_sqlite/1)

  @doc "Runs `convert_to_postgres/1` on `TARGET_DATABASE_URL` and halts with status 1 on error."
  def convert_to_postgres!, do: convert!(:sqlite, "TARGET_DATABASE_URL", &convert_to_postgres/1)

  defp convert!(source, variable, fun) do
    Application.load(@app)

    result =
      case {Application.fetch_env!(@app, :database), System.get_env(variable, "")} do
        {^source, ""} -> {:error, {:missing, variable}}
        {^source, target} -> fun.(target)
        _other -> {:error, {:source_is_not, source}}
      end

    case result do
      :ok ->
        IO.puts("Converted. Point the configuration at the new database before starting Sikio.")

      {:error, reason} ->
        IO.puts("Nothing was converted: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # Starts both repositories without names, so neither claims `Sikio.Repo`.
  defp convert({source_module, source_opts}, {target_module, target_opts}) do
    Application.load(@app)
    opts = [name: nil, pool: DBConnection.ConnectionPool, pool_size: 2]
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    [source, target] =
      for {module, config} <- [{source_module, source_opts}, {target_module, target_opts}] do
        {:ok, _} = module.__adapter__().ensure_all_started(config, :temporary)
        {:ok, repo} = module.start_link(Keyword.merge(config, opts))
        repo
      end

    try do
      with :ok <- unused(target_module, target) do
        migrations = Application.app_dir(@app, "priv/repo/migrations")
        Ecto.Migrator.run(target_module, migrations, :up, all: true, dynamic_repo: target)
        Convert.copy({source_module, source}, {target_module, target})
      end
    after
      Enum.each([source, target], &Supervisor.stop/1)
    end
  end

  # A mistyped URL must not migrate another application's database before the refusal.
  defp unused(Postgres, target) do
    case SQL.query!(
           target,
           "SELECT count(*) FROM information_schema.tables WHERE table_schema = current_schema()"
         ) do
      %{rows: [[0]]} -> :ok
      _ -> {:error, :target_not_empty}
    end
  end

  # `convert_to_sqlite/2` creates the file, so it holds nothing yet.
  defp unused(SQLite, _target), do: :ok

  defp repo_config, do: Application.get_env(@app, Sikio.Repo, [])

  # Starts the repository for one call and stops it afterwards, as `migrate/0` does.
  # Neither starts the endpoint or Oban.
  defp with_repo(fun) do
    Application.load(@app)
    repo = hd(Application.fetch_env!(@app, :ecto_repos))

    case Ecto.Migrator.with_repo(repo, fn _repo -> fun.() end) do
      {:ok, result, _started} -> result
      other -> other
    end
  end
end
