# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.HTTP do
  @moduledoc """
  Bounded public HTTP requests with DNS pinning and per-hop validation.

  Every URL comes from user input or from a subscribed feed, so every request target is untrusted.
  Without destination checks this allows server-side request forgery (SSRF).
  A hostname check alone is insufficient. The host is resolved once, and every address must be
  public. The connection goes to the checked address. The original hostname is still sent as the
  `Host` header and used for TLS SNI and certificate verification.
  """
  import Bitwise

  alias Sikio.Feeds.Transport

  # Unspecified, private, carrier-grade NAT, loopback, link-local, IETF protocol assignments, the
  # three documentation ranges, benchmarking, multicast and reserved. Stored as network and prefix
  # length instead of CIDR strings, so a comparison is two shifts.
  @blocked_v4 [
    {0x00000000, 8},
    {0x0A000000, 8},
    {0x64400000, 10},
    {0x7F000000, 8},
    {0xA9FE0000, 16},
    {0xAC100000, 12},
    {0xC0000000, 24},
    {0xC0000200, 24},
    {0xC0A80000, 16},
    {0xC6120000, 15},
    {0xC6336400, 24},
    {0xCB007100, 24},
    {0xE0000000, 4},
    {0xF0000000, 4}
  ]

  def get(url, opts \\ []) do
    follow(url, opts, 4)
  end

  @doc """
  Parses a pasted URL into a URI this application may fetch.

  The 2,048-byte limit also protects the database. The feed URL has a unique index, and an index
  entry must fit in an index page.
  """
  def normalize(url) when is_binary(url) and byte_size(url) <= 2048 do
    url = String.trim(url)
    url = if String.contains?(url, "://"), do: url, else: "https://" <> url

    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, port: port} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and port in [80, 443] ->
        if Regex.match?(~r/\A[a-zA-Z0-9.:-]+\z/, host),
          do: {:ok, %{uri | host: String.downcase(host), fragment: nil}},
          else: {:error, :unsafe_url}

      _ ->
        {:error, :unsafe_url}
    end
  end

  def normalize(_url), do: {:error, :unsafe_url}

  @doc """
  Resolves an `href` against the URL of the document that contains it, then validates it.

  `normalize/1` handles pasted input, where a bare host is the likely intent. An `href` may be
  relative: `art/1.jpg` is a file next to the feed. Prefixing a scheme would make `art` the host.
  Returns the URL string, or `nil` when it is empty or fails validation.
  """
  def resolve(href, base) when is_binary(href) and is_binary(base) do
    case href |> String.trim() |> merged(base) |> normalize() do
      {:ok, uri} -> URI.to_string(uri)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def resolve(_href, _base), do: nil

  # `URI.merge` with an empty href returns the base URL. An absent href would then resolve to the
  # document itself.
  defp merged("", _base), do: ""
  defp merged(href, base), do: base |> URI.merge(href) |> URI.to_string()

  def public_address?({a, b, c, d}) do
    ip = (a <<< 24) + (b <<< 16) + (c <<< 8) + d

    Enum.all?(@blocked_v4, fn {network, bits} -> ip >>> (32 - bits) != network >>> (32 - bits) end)
  end

  # Only global unicast IPv6; exclude tunnelling and special/documentation assignments.
  def public_address?({a, b, _, _, _, _, _, _}) do
    a in 0x2000..0x3FFF and a != 0x2002 and
      not (a == 0x2001 and (b < 0x0200 or b == 0x0DB8)) and
      not (a == 0x3FFF and b < 0x1000)
  end

  def public_address?(_ip), do: false

  defp follow(_url, _opts, -1), do: {:error, :too_many_redirects}

  defp follow(url, opts, remaining) do
    with {:ok, uri} <- normalize(url),
         {:ok, address} <- address(uri.host),
         {:ok, response} <- request(uri, address, opts) do
      received(response, uri, opts, remaining)
    end
  rescue
    _error in [ArgumentError, URI.Error] -> {:error, :unsafe_url}
  end

  # Redirects are followed here, not in the transport. Each hop is a new destination and is
  # resolved and checked like the first.
  defp received(%{status: status} = response, uri, opts, remaining)
       when status in [301, 302, 303, 307, 308] do
    case Map.get(response.headers, "location", []) do
      [location] -> follow(uri |> URI.merge(location) |> URI.to_string(), opts, remaining - 1)
      _ -> {:error, :unavailable}
    end
  end

  defp received(response, uri, _opts, _remaining) do
    {:ok, Map.put(response, :url, URI.to_string(uri))}
  end

  defp address(host) do
    result =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} -> {:ok, [ip]}
        _ -> Application.get_env(:sikio, :feed_resolver, &resolve/1).(host)
      end

    case result do
      # Every resolved address must be public, not only the one used. A mix of public and private
      # addresses is a DNS rebinding pattern.
      {:ok, [first | _] = addresses} ->
        if Enum.all?(addresses, &public_address?/1), do: {:ok, first}, else: {:error, :unsafe_url}

      _ ->
        {:error, :unavailable}
    end
  end

  # Both families are queried concurrently, so a missing record type costs one timeout, not two.
  # IPv4 addresses come first, and the request uses the first address.
  defp resolve(host) do
    name = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Task.async_stream(&:inet.getaddrs(name, &1, 2_000), timeout: :infinity)
      |> Enum.flat_map(fn
        {:ok, {:ok, ips}} -> ips
        _ -> []
      end)

    {:ok, addresses}
  end

  defp request(uri, address, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, 8_000_000)

    headers =
      [
        {"host", uri.host},
        {"accept-encoding", "identity"},
        {"user-agent", "Sikio/0.1 RSS reader"}
      ] ++ Keyword.get(opts, :headers, [])

    with {:ok, response} <- Transport.fetch(uri, address, headers, max_bytes) do
      check_response(response, max_bytes)
    end
  end

  defp check_response(response, limit) do
    cond do
      byte_size(response.body) > limit ->
        {:error, :too_large}

      # The request sets `accept-encoding: identity`. Nothing decodes a compressed body.
      # Decompression would also bypass the size limit.
      Map.get(response.headers, "content-encoding", []) not in [[], ["identity"]] ->
        {:error, :unsupported_encoding}

      true ->
        {:ok, response}
    end
  end
end
