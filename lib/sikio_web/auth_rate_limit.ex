# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AuthRateLimit do
  @moduledoc """
  Limits auth requests per visitor address, as `SikioWeb.ClientIp` resolved it.

  That address comes from the forwarding header when a trusted proxy carried the request, and
  from the socket otherwise. Counting the socket behind a proxy would give everybody one budget.
  `ClientIp.bucket/1` says what counts as one visitor, which for IPv6 is the allocation.
  """
  @behaviour Plug
  import Plug.Conn
  alias Sikio.AuthRateLimiter
  alias SikioWeb.ClientIp

  @impl true
  def init(opts), do: opts

  @defaults [recovery: {10, 60}, ceremony: {120, 60}, setup: {10, 60}]

  @doc """
  The `{limit, seconds}` budget for one group of auth requests.

  One reader for the whole key, so a group named here is a group every caller can ask for. The
  fallback is per group rather than for the key as a whole: configuring one budget replaces the
  list, and a list that then lacks a group must not make every request under it fail.
  """
  def budget(group) do
    :sikio
    |> Application.get_env(:auth_rate_limits, [])
    |> Keyword.get(group) || Keyword.fetch!(@defaults, group)
  end

  @doc """
  The counter key for one group of requests from this visitor.

  Built here so that every budget in the application is counted the same way. A caller that spelt
  the key itself would be one endpoint away from counting an IPv6 visitor per address, and the
  budget would mean nothing there without anything saying so.
  """
  def key(conn, group), do: {group, ClientIp.bucket(conn.remote_ip)}

  @impl true
  def call(conn, _opts) do
    group = if conn.request_path == "/auth/recovery", do: :recovery, else: :ceremony
    {limit, seconds} = budget(group)

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
