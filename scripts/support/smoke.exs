Code.require_file("support.exs", __DIR__)

defmodule Sikio.ReleaseSmoke.Smoke do
  @moduledoc "Shared helpers for disposable operational smoke checks."
  alias Sikio.ReleaseSmoke.Support
  @root Path.expand("../..", __DIR__)

  def release, do: Path.join(@root, "_build/prod/rel/sikio/bin")
  def run(args, env), do: args |> Support.run(env) |> String.trim()
  def query(sql, env), do: run(["psql", "-X", "-v", "ON_ERROR_STOP=1", "-Atc", sql], env)

  def database_env(database) do
    env = System.get_env()
    user = URI.encode(env["PGUSER"] || "postgres", &URI.char_unreserved?/1)
    password = URI.encode(env["PGPASSWORD"] || "", &URI.char_unreserved?/1)
    credentials = user <> if(password == "", do: "", else: ":" <> password)

    url =
      "ecto://#{credentials}@#{env["PGHOST"] || "localhost"}:#{env["PGPORT"] || "5432"}/#{database}"

    Map.merge(env, %{
      "PGDATABASE" => database,
      "PGCONNECT_TIMEOUT" => "5",
      "DATABASE_URL" => url,
      "SECRET_KEY_BASE" => Support.token(64),
      "PHX_HOST" => "localhost",
      "PHX_BIND_IP" => "127.0.0.1"
    })
  end

  def with_database(name, env, fun) do
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
    Application.ensure_all_started(:inets)
    url = String.to_charlist("http://#{host}:#{port}#{path}")
    headers = [{~c"host", ~c"localhost"}, {~c"x-forwarded-proto", ~c"https"}]

    case :httpc.request(:get, {url, headers}, [timeout: 3_000, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_, 200, _}, _, body}} -> body
      _ -> raise "HTTP probe failed"
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
