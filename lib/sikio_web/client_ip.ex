# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ClientIp do
  @moduledoc """
  The visitor's address, taken from the proxy's header only when the proxy is the one asking.

  Every budget in this application is spent per address, so the address decides who a refusal
  refuses. Behind a reverse proxy the socket always comes from the same place, and counting that
  would give every visitor one shared budget: one stranger spending it would lock out everybody
  else, including the operator with a setup code in hand.

  `X-Forwarded-For` carries the address that would fix it, and it is written by whoever sends the
  request. Believing it without asking where it came from is the opposite mistake, and a worse
  one: a visitor would pick their own budget and no limit would mean anything.

  So it is believed on one condition, which is the connection it arrived on. The loopback is
  trusted because that is where a proxy on the same host speaks from. `:trusted_proxies` names
  any others, as addresses `config/runtime.exs` has already parsed and checked.

  The header is read here rather than by a library. The one for this reads three further headers
  by default, which a proxy does not write and a visitor therefore can; and its notion of a
  private address overrules the proxies it was told about, so naming an internal proxy on
  `10.0.0.2` made it the visitor for everybody behind it. Both measured. The rule this needs is
  one sentence long, and it is the one below.
  """
  @behaviour Plug

  # The one header the proxy writes. A proxy appends the address it saw to whatever arrived, so
  # the rightmost entry that is not one of our own is the visitor.
  @header "x-forwarded-for"

  @localhost {0, 0, 0, 0, 0, 0, 0, 1}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    proxies = Enum.map(configured(), &unmapped/1)
    peer = unmapped(conn.remote_ip)
    visitor = if trusted?(peer, proxies), do: forwarded(conn, proxies) || peer, else: peer

    # The socket is kept as well. `remote_ip` answers who the request is from, which behind a
    # proxy is the visitor, and that is what a log line and every budget should name. Which
    # machine actually opened the connection is a different question, and an operator chasing a
    # misconfigured proxy needs it.
    %{conn | remote_ip: visitor} |> Plug.Conn.assign(:socket_peer_ip, peer)
  end

  @doc """
  The address a budget is counted against.

  A visitor with IPv6 usually holds a whole `/64`, and moving inside it is free. Counting the
  exact address would turn ten attempts a minute into as many as somebody cares to make, now that
  the address can come from a header. So the allocation is counted. An IPv4 address is one
  address and is counted as it is.
  """
  def bucket({_, _, _, _} = address), do: address
  def bucket({a, b, c, d, _, _, _, _}), do: {a, b, c, d, 0, 0, 0, 0}

  defp forwarded(conn, proxies) do
    conn
    |> Plug.Conn.get_req_header(@header)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&address/1)
    |> Enum.reverse()
    |> Enum.find(&(&1 && not trusted?(&1, proxies)))
  end

  defp address(entry) do
    case entry |> String.trim() |> to_charlist() |> :inet.parse_strict_address() do
      {:ok, parsed} -> unmapped(parsed)
      {:error, _reason} -> nil
    end
  end

  # The whole `127.0.0.0/8`, because giving each backend its own loopback address is an ordinary
  # way to run several of them.
  defp trusted?({127, _, _, _}, _proxies), do: true
  defp trusted?(@localhost, _proxies), do: true
  defp trusted?(address, proxies), do: address in proxies

  defp configured, do: Application.get_env(:sikio, :trusted_proxies, [])

  # A dual-stack socket reports an IPv4 peer in its mapped form, and production binds `::`. Caddy
  # on the same host then arrives as `{0, 0, 0, 0, 0, 65535, 32512, 1}`, which matches no loopback
  # written the plain way. Without this the plug does nothing on the one deployment it is for,
  # and quietly: a test built on `Plug.Test.conn/3` never sees the mapped form.
  defp unmapped({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    {Bitwise.bsr(high, 8), Bitwise.band(high, 0xFF), Bitwise.bsr(low, 8), Bitwise.band(low, 0xFF)}
  end

  defp unmapped(address), do: address
end
