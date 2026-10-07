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

  # Bytes rather than `to_charlist/1`, which raises on a header that is not valid UTF-8. A
  # visitor writes those bytes and this plug runs before everything, so the raise would be a
  # request nobody can make succeed.
  defp address(entry) do
    case entry |> :erlang.binary_to_list() |> :string.trim() |> :inet.parse_strict_address() do
      {:ok, parsed} -> unmapped(parsed)
      {:error, _reason} -> nil
    end
  end

  # The whole `127.0.0.0/8`, because giving each backend its own loopback address is an ordinary
  # way to run several of them.
  defp trusted?({127, _, _, _}, _proxies), do: true
  defp trusted?(@localhost, _proxies), do: true
  defp trusted?(address, proxies), do: Enum.any?(proxies, &covers?(&1, address))

  # A range covers the addresses that share its leading bits, in its own family only.
  defp covers?({network, bits}, address) when tuple_size(network) == tuple_size(address),
    do: leading(network, bits) == leading(address, bits)

  defp covers?({_network, _bits}, _address), do: false
  defp covers?(proxy, address), do: proxy == address

  defp leading(address, bits) do
    part = if tuple_size(address) == 4, do: 8, else: 16
    whole = for n <- Tuple.to_list(address), into: <<>>, do: <<n::size(part)>>
    <<head::bitstring-size(^bits), _rest::bitstring>> = whole
    head
  end

  @doc """
  One entry of `TRUSTED_PROXIES`: an address, or a range written as the address it starts at and
  how many leading bits the others share, such as `172.20.0.0/16`. Anything else is `:error`.
  """
  def parse_proxy(entry) do
    case String.split(entry, "/") do
      [address] -> strict_address(address)
      [address, bits] -> range(strict_address(address), Integer.parse(bits))
      _ -> :error
    end
  end

  defp strict_address(text) do
    case :inet.parse_strict_address(to_charlist(text)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp range({:ok, address}, {bits, ""}) when bits >= 0 do
    if bits <= width(address), do: {:ok, {address, bits}}, else: :error
  end

  defp range(_address, _bits), do: :error

  defp width(address) when tuple_size(address) == 4, do: 32
  defp width(_address), do: 128

  defp configured, do: Application.get_env(:sikio, :trusted_proxies, [])

  # A dual-stack socket reports an IPv4 peer in its mapped form, and production binds `::`. Caddy
  # on the same host then arrives as `{0, 0, 0, 0, 0, 65535, 32512, 1}`, which matches no loopback
  # written the plain way. Without this the plug does nothing on the one deployment it is for,
  # and quietly: a test built on `Plug.Test.conn/3` never sees the mapped form.
  # The guard is the whole check: OTP's conversion reads the low bits of whatever it is handed
  # and does not ask whether the address was mapped.
  defp unmapped({0, 0, 0, 0, 0, 0xFFFF, _high, _low} = address),
    do: :inet.ipv4_mapped_ipv6_address(address)

  defp unmapped(address), do: address
end
