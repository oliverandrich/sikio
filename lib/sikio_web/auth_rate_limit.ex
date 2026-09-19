defmodule SikioWeb.AuthRateLimit do
  @moduledoc "Limits auth requests using the socket peer IP, never untrusted forwarding headers."
  @behaviour Plug
  import Plug.Conn
  alias Sikio.AuthRateLimiter

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    group = if conn.request_path == "/auth/recovery", do: :recovery, else: :ceremony

    limits =
      Application.get_env(:sikio, :auth_rate_limits, recovery: {10, 60}, ceremony: {120, 60})

    {limit, seconds} = Keyword.fetch!(limits, group)

    case AuthRateLimiter.check({group, conn.remote_ip}, limit, seconds) do
      :ok ->
        conn

      {:error, retry_after} ->
        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after))
        |> put_resp_header("cache-control", "no-store")
        |> put_status(429)
        |> Phoenix.Controller.json(%{error: "rate_limited"})
        |> halt()
    end
  end
end
