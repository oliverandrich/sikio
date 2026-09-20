# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.HTTP do
  @moduledoc """
  Bounded public HTTP requests with DNS pinning and per-hop validation.

  Every address in this application comes from somebody pasting it, so each one is treated as a
  request to fetch a URL the server chooses. That is server-side request forgery unless the
  destination is checked, and checking the hostname is not enough: the name is resolved once, every
  answer is required to be public, and the connection then goes to the address that was checked
  while the original hostname still carries the `Host` header and the TLS handshake.
  """
  import Bitwise

  # Unspecified, private, carrier-grade NAT, loopback, link-local, the three documentation ranges,
  # benchmarking, multicast and reserved. Written as network and prefix length rather than as CIDR
  # strings so the comparison is two shifts.
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
  Parses a pasted address into a URI this application is willing to fetch.

  The length limit is the database's as much as this module's: the URL is a unique index, and an
  address longer than the page it would sit on cannot be stored.
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
  An address written inside a document, resolved against that document and then checked.

  `normalize/1` answers for something somebody pasted, where a bare host is the likely intent.
  An `href` is not pasted: `art/1.jpg` names a file beside the feed, and prefixing a scheme
  turns it into a host called `art`. Answers the address, or `nil` when there is none to trust.
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

  # Merging nothing against an address answers that address, so an absent href would resolve to
  # the document that does not carry it.
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

  # Redirects are followed here rather than by Req, because every hop is a new destination and has
  # to be resolved and checked like the first one.
  defp received(%{status: status} = response, uri, opts, remaining)
       when status in [301, 302, 303, 307, 308] do
    case Req.Response.get_header(response, "location") do
      [location] -> follow(uri |> URI.merge(location) |> URI.to_string(), opts, remaining - 1)
      _ -> {:error, :unavailable}
    end
  end

  defp received(response, uri, _opts, _remaining) do
    {:ok,
     %{
       status: response.status,
       headers: response.headers,
       body: response.body,
       url: URI.to_string(uri)
     }}
  end

  defp address(host) do
    result =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} -> {:ok, [ip]}
        _ -> Application.get_env(:sikio, :feed_resolver, &resolve/1).(host)
      end

    case result do
      # Every answer has to be public, not just the one that will be used: a name that resolves to
      # a public address and a private one is the shape of a rebinding attempt.
      {:ok, [first | _] = addresses} ->
        if Enum.all?(addresses, &public_address?/1), do: {:ok, first}, else: {:error, :unsafe_url}

      _ ->
        {:error, :unavailable}
    end
  end

  defp resolve(host) do
    addresses =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(String.to_charlist(host), family, 2_000) do
          {:ok, ips} -> ips
          _ -> []
        end
      end)

    {:ok, addresses}
  end

  defp request(uri, address, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, 8_000_000)
    pinned = %{uri | host: address |> :inet.ntoa() |> to_string()}

    headers =
      [
        {"host", uri.host},
        {"accept-encoding", "identity"},
        {"user-agent", "Sikio/0.1 RSS reader"}
      ] ++ Keyword.get(opts, :headers, [])

    options = [
      redirect: false,
      retry: false,
      raw: true,
      compressed: false,
      receive_timeout: 10_000,
      finch: [
        pool_timeout: 5_000,
        request_timeout: 15_000,
        pool_max_idle_time: 60_000,
        conn_opts: [
          hostname: uri.host,
          transport_opts: [timeout: 5_000, inet6: tuple_size(address) == 8]
        ]
      ],
      headers: headers,
      into: collector(max_bytes)
    ]

    options =
      case Application.get_env(:sikio, :feed_http_plug) do
        nil -> options
        plug -> Keyword.put(options, :plug, plug)
      end

    case Req.get(URI.to_string(pinned), options) do
      {:ok, response} -> check_response(response, max_bytes)
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp check_response(response, limit) do
    cond do
      byte_size(response.body) > limit ->
        {:error, :too_large}

      # Identity encoding was asked for. A peer that compressed anyway would have its body decoded
      # by nobody, and a decompressor is a size limit's way around itself.
      Req.Response.get_header(response, "content-encoding") not in [[], ["identity"]] ->
        {:error, :unsupported_encoding}

      true ->
        {:ok, response}
    end
  end

  defp collector(limit) do
    fn {:data, bytes}, {request, response} ->
      # Retain only one overflow byte, even when a peer sends a large single chunk.
      remaining = max(0, limit + 1 - byte_size(response.body))
      body = response.body <> binary_part(bytes, 0, min(byte_size(bytes), remaining))
      action = if byte_size(body) > limit, do: :halt, else: :cont
      {action, {request, %{response | body: body}}}
    end
  end
end
