# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ClientIp do
  @moduledoc """
  A plug that sets `remote_ip` to the client address.

  It reads `X-Forwarded-For` only when the socket peer is a trusted proxy.

  Rate limits count per address. Behind a reverse proxy every socket peer is the proxy.
  Counting the peer would give all clients one shared budget.

  Any client can send `X-Forwarded-For`. Trusting it unconditionally would let a client
  choose its own rate-limit key.

  Loopback peers are trusted, because a proxy on the same host connects from there.
  `:trusted_proxies` lists other proxies, already parsed and validated in `config/runtime.exs`.

  The header is parsed here, not by a library. The library considered reads three more headers
  by default, which a client can set. Its private-address handling also overrode the configured
  proxies. With an internal proxy on `10.0.0.2`, that proxy became the client address. Both
  were verified.
  """
  @behaviour Plug

  # Each proxy appends its peer address. The rightmost untrusted entry is the client.
  @header "x-forwarded-for"

  @localhost {0, 0, 0, 0, 0, 0, 0, 1}

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    proxies = Enum.map(configured(), &unmapped/1)
    peer = unmapped(conn.remote_ip)
    visitor = if trusted?(peer, proxies), do: forwarded(conn, proxies) || peer, else: peer

    # `remote_ip` holds the client address for logs and rate limits.
    # `:socket_peer_ip` keeps the socket peer for debugging a proxy configuration.
    %{conn | remote_ip: visitor} |> Plug.Conn.assign(:socket_peer_ip, peer)
  end

  @doc """
  Returns the address a rate limit counts against.

  An IPv6 client usually holds a whole `/64` and can switch addresses within it.
  Counting exact addresses would let one client multiply its budget.
  IPv6 addresses are therefore reduced to their `/64` prefix. IPv4 addresses are used as they are.
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

  # Uses `:erlang.binary_to_list/1`, because `to_charlist/1` raises on invalid UTF-8.
  # The client controls the header, and this plug runs early in the endpoint.
  # A raise would fail every request carrying such a header.
  defp address(entry) do
    case entry |> :erlang.binary_to_list() |> :string.trim() |> :inet.parse_strict_address() do
      {:ok, parsed} -> unmapped(parsed)
      {:error, _reason} -> nil
    end
  end

  # Trusts all of `127.0.0.0/8`. Several backends may each use their own loopback address.
  defp trusted?({127, _, _, _}, _proxies), do: true
  defp trusted?(@localhost, _proxies), do: true
  defp trusted?(address, proxies), do: Enum.any?(proxies, &covers?(&1, address))

  # A range matches addresses of the same family that share its prefix bits.
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
  Parses one `TRUSTED_PROXIES` entry: an address or a CIDR range such as `172.20.0.0/16`.

  Returns `:error` for anything else.
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

  # A dual-stack socket reports IPv4 peers as IPv4-mapped IPv6 addresses. Production binds `::`.
  # Caddy on the same host then appears as `{0, 0, 0, 0, 0, 65535, 32512, 1}`.
  # That address matches no plain loopback pattern, so the proxy would not be trusted.
  # Tests built on `Plug.Test.conn/3` never produce the mapped form.
  # The guard does the check. OTP's conversion reads the low bits without checking the prefix.
  defp unmapped({0, 0, 0, 0, 0, 0xFFFF, _high, _low} = address),
    do: :inet.ipv4_mapped_ipv6_address(address)

  defp unmapped(address), do: address
end
