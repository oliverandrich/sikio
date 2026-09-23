# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AuthRateLimit do
  @moduledoc """
  What every budget in this application is counted against, and how much of it there is.

  As a plug it limits auth requests per visitor address, as `SikioWeb.ClientIp` resolved it: from
  the forwarding header when a trusted proxy carried the request, and from the socket otherwise.
  Counting the socket behind a proxy would give everybody one budget, and `ClientIp.bucket/1`
  says what counts as one visitor, which for IPv6 is the allocation.

  `key/2` also answers for an account, which is what bounds how many invitations one member may
  make. A browser is the wrong thing to count there: what is being spent belongs to the account.
  """
  @behaviour Plug
  import Plug.Conn
  alias Sikio.Accounts.User
  alias Sikio.AuthRateLimiter
  alias SikioWeb.ClientIp

  @impl true
  def init(opts), do: opts

  @doc """
  The counter key for one group of requests, from an account or from a visitor.

  Built here so that every budget in the application is counted the same way. A caller that spelt
  the key itself would be one endpoint away from counting an IPv6 visitor per address, and the
  budget would mean nothing there without anything saying so.

  An account is counted by its own id and not by the browser in front of it: a session, a name or
  an address would each let the same person start over, and the account is what is spending.
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
