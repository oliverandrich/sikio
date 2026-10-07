# SPDX-License-Identifier: AGPL-3.0-or-later

Code.require_file("support.exs", __DIR__)

defmodule Sikio.ReleaseSmoke.Smoke do
  @moduledoc "Shared helpers for disposable operational smoke checks."
  alias Sikio.ReleaseSmoke.Support
  @root Path.expand("../..", __DIR__)

  # The database the release is started with.
  def database, do: System.get_env("SIKIO_DATABASE", "sqlite")

  def release, do: Path.join(@root, "_build/prod/rel/sikio/bin")
  def run(args, env), do: args |> Support.run(env) |> String.trim()

  @doc "Whether the migrated schema holds `table`."
  def table?(table, env) do
    case database() do
      "sqlite" ->
        sql = "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '#{table}'"
        run(["sqlite3", env["DATABASE_PATH"], sql], env) == "1"

      "postgres" ->
        sql = "SELECT to_regclass('public.#{table}') IS NOT NULL"
        run(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", sql], env) == "t"
    end
  end

  @doc """
  The environment a release needs to boot, with a database of its own named `database`. A SQLite
  release keeps its file in `directory`, which the caller removes.
  """
  def database_env(database, directory) do
    case database() do
      "sqlite" ->
        Map.put(boot_env(), "DATABASE_PATH", Path.join(directory, database <> ".db"))

      "postgres" ->
        postgres_env(database)
    end
  end

  defp boot_env do
    Map.merge(System.get_env(), %{
      "SECRET_KEY_BASE" => Support.token(64),
      "PHX_HOST" => "localhost",
      "PHX_BIND_IP" => "127.0.0.1"
    })
  end

  defp postgres_env(database) do
    env = System.get_env()
    user = URI.encode(env["PGUSER"] || "postgres", &URI.char_unreserved?/1)
    password = URI.encode(env["PGPASSWORD"] || "", &URI.char_unreserved?/1)
    credentials = user <> if(password == "", do: "", else: ":" <> password)

    url =
      "ecto://#{credentials}@#{env["PGHOST"] || "localhost"}:#{env["PGPORT"] || "5432"}/#{database}"

    Map.merge(boot_env(), %{
      "PGDATABASE" => database,
      "PGCONNECT_TIMEOUT" => "5",
      "DATABASE_URL" => url
    })
  end

  @doc "Runs `fun` with the database in place. A SQLite release creates its file itself."
  def with_database(name, env, fun) do
    if database() == "sqlite", do: fun.(), else: with_postgres(name, env, fun)
  end

  defp with_postgres(name, env, fun) do
    run(["createdb", name], env)

    try do
      fun.()
    after
      run(["dropdb", name], env)
    end
  end

  def eventually(fun, description, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    retry(fun, description, deadline)
  end

  defp retry(fun, description, deadline) do
    fun.()
  rescue
    error in [RuntimeError, ExUnit.AssertionError, Support.CommandError] ->
      if System.monotonic_time(:millisecond) >= deadline do
        reraise "Timed out: #{description} (#{inspect(error.__struct__)})", __STACKTRACE__
      end

      receive do
      after
        100 -> retry(fun, description, deadline)
      end
  end

  @doc """
  Waits until the application answers, and returns the page an empty instance serves.

  Both probe paths live here rather than in each smoke script, because `/` belongs to a signed-in
  visitor and answers a redirect. `/health` says the HTTP stack is up, and `/setup` is a rendered
  page, which is what proves the layout and its built assets came along.
  """
  def await_landing(host, port, description) do
    eventually(fn -> http(host, port, "/health") end, description)
    http(host, port, "/setup")
  end

  def http(host, port, path) do
    case request(host, port, path, [{"host", "localhost"}, {"x-forwarded-proto", "https"}]) do
      {200, _headers, body} -> body
      _ -> raise "HTTP probe failed"
    end
  end

  @doc "One request without following redirects: the status, the headers by lowercase name and the body."
  def request(address, port, path, headers) do
    Application.ensure_all_started(:inets)
    url = String.to_charlist("http://#{address}:#{port}#{path}")
    headers = Enum.map(headers, fn {name, value} -> {~c"#{name}", ~c"#{value}"} end)

    case :httpc.request(:get, {url, headers}, [timeout: 3_000, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, response_headers, body}} ->
        {status, Map.new(response_headers, fn {name, value} -> {"#{name}", "#{value}"} end), body}

      {:error, _reason} ->
        raise "HTTP probe failed"
    end
  end

  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    Integer.to_string(port)
  end

  def with_server(executable, env, fun) do
    # Closing this Port closes stdin of the supervisor shell, which always reaps
    # the release process before exiting (including when the Elixir VM exits).
    Support.temporary(fn directory ->
      log = Path.join(directory, "server.log")

      shell = ~S"""
      "$1" >"$2" 2>&1 &
      child=$!
      trap 'kill "$child" 2>/dev/null || :; wait "$child" 2>/dev/null || :' EXIT
      read done
      """

      port =
        Port.open({:spawn_executable, System.find_executable("sh")}, [
          :binary,
          :exit_status,
          args: ["-c", shell, "sikio-server", executable, log],
          env:
            Enum.map(env, fn {key, value} ->
              {String.to_charlist(key), String.to_charlist(value)}
            end)
        ])

      try do
        fun.()
      after
        Port.command(port, "done\n")

        receive do
          {^port, {:exit_status, _}} -> :ok
        after
          15_000 -> Port.close(port)
        end
      end
    end)
  end
end
