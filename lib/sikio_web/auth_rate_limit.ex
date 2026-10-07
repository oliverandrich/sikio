# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AuthRateLimit do
  @moduledoc """
  Rate-limit keys for auth requests, and a plug that enforces the ceremony and recovery budgets.

  The plug counts requests per client address, as `SikioWeb.ClientIp` resolved it.
  Behind a trusted proxy that is the forwarded address, otherwise the socket peer.
  `ClientIp.bucket/1` groups IPv6 addresses by their `/64` prefix.

  `key/2` also accepts an account. The invitation budget is counted per account.
  """
  @behaviour Plug
  import Plug.Conn
  alias Sikio.Accounts.User
  alias Sikio.AuthRateLimiter
  alias SikioWeb.ClientIp

  @impl true
  def init(opts), do: opts

  @doc """
  Returns the counter key for a request group, from an account or a connection.

  All callers build keys here, so IPv6 clients are always bucketed by `/64` prefix.

  An account is keyed by its id. A session, username or address would let the same account
  reset its count.
  """
  def key(%User{id: id}, group), do: {group, id}
  def key(%Plug.Conn{} = conn, group), do: {group, ClientIp.bucket(conn.remote_ip)}

  @impl true
  def call(conn, _opts) do
    group = if conn.request_path == "/auth/recovery", do: :recovery, else: :ceremony
    {limit, seconds} = AuthRateLimiter.budget(group)

    case AuthRateLimiter.check(key(conn, group), limit, seconds) do
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
