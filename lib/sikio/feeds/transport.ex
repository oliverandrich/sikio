# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Transport do
  @moduledoc """
  Opens one connection per request and closes it afterwards.

  DNS pinning makes a connection pool expensive. Pinning connects to the checked address and
  passes the hostname for SNI and certificate verification. The hostname thus becomes a
  connection option, and pools are keyed by their options. `Req` hashes the options into a module
  name. That interns an atom and starts a supervised `Finch` pool under it. Measured: twenty
  hostnames cost twenty supervision trees and 190 atoms, and neither is released. The atom table
  is capped, and exhausting it crashes the VM.

  A feed is polled once per interval, an hour by default, so a pool would rarely reuse a
  connection. One connection per request is cheaper and bounded.

  Only HTTP/1 is used. A feed is one document, so HTTP/2 flow control gains nothing here.
  """
  @connect_timeout 5_000
  @read_timeout 10_000
  @response_timeout 15_000

  @doc """
  Fetches one document from an already checked address.

  `uri` is the requested URL and `address` the connection target. They differ on purpose.
  The connection goes to the checked address. The hostname in `uri` is used for SNI and
  certificate verification.

  A plug can replace the peer. All tests use one through the `:feed_http_plug` setting.
  The substitution lives here, because replacing the socket is this module's concern. The
  `plug:` option overrides the setting. This module's tests pass `plug: nil` to use a real socket.

  `cacerts:` replaces the system trust store. Only tests pass it, with their own certificate
  authority, to verify certificates in a real TLS handshake.

  `method:` and `body:` send a request other than a GET, such as a form POST.
  """
  def fetch(uri, address, headers, limit, opts \\ []) do
    case Keyword.get(opts, :plug, Application.get_env(:sikio, :feed_http_plug)) do
      nil -> connect(uri, address, headers, limit, opts)
      plug -> through(plug, pinned(uri, address), headers, opts)
    end
  end

  defp pinned(uri, address), do: %{uri | host: address |> :inet.ntoa() |> to_string()}

  defp connect(uri, address, headers, limit, opts) do
    scheme = if uri.scheme == "https", do: :https, else: :http

    options = [
      hostname: uri.host,
      mode: :passive,
      protocols: [:http1],
      transport_opts:
        [timeout: @connect_timeout, inet6: tuple_size(address) == 8] ++
          Keyword.take(opts, [:cacerts])
    ]

    case Mint.HTTP.connect(scheme, pinned(uri, address).host, uri.port, options) do
      {:ok, conn} -> request(conn, uri, headers, limit, opts)
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    # Connecting can raise, for example when the host has no system trust store. The caller then
    # gets `:unavailable`. Unrescued, the exception would fail the Oban job, or the rescue in
    # `Sikio.Feeds.HTTP` would report `:unsafe_url`, which is the wrong cause.
    _error -> {:error, :unavailable}
  end

  # The conn targets the pinned address and carries the real request headers. A stub can assert
  # on pinning without a socket.
  #
  # Nothing is rescued here. A raising stub usually means a test forgot to register one.
  # Rescuing would turn that into a plausible server failure, and the test would pass wrongly.
  defp through(plug, uri, headers, opts) do
    {module, options} = if is_tuple(plug), do: plug, else: {plug, []}

    opts
    |> Keyword.get(:method, "GET")
    |> Plug.Test.conn(URI.to_string(uri), Keyword.get(opts, :body))
    |> put_headers(headers)
    |> module.call(module.init(options))
    |> answered()
  end

  # Appended to `req_headers` directly, because `put_req_header/3` rejects `host`.
  # The plug receives the request as sent, and `host` carries the original hostname for pinning.
  defp put_headers(conn, headers) do
    sent = Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)
    %{conn | req_headers: conn.req_headers ++ sent}
  end

  # A plug that returns the conn without a response has no status. It is not an empty body.
  # Reading a body from it would raise, and the error would be reported as `:unsafe_url`.
  defp answered(%{status: nil}), do: {:error, :unavailable}

  defp answered(conn) do
    {:ok, %{status: conn.status, headers: headers(conn.resp_headers), body: conn.resp_body || ""}}
  end

  defp request(conn, uri, headers, limit, opts) do
    method = Keyword.get(opts, :method, "GET")

    case Mint.HTTP.request(conn, method, path(uri), headers, Keyword.get(opts, :body)) do
      {:ok, conn, ref} ->
        deadline = System.monotonic_time(:millisecond) + @response_timeout
        {conn, result} = receive_response(conn, ref, limit, deadline, blank())
        Mint.HTTP.close(conn)
        result

      {:error, conn, _reason} ->
        Mint.HTTP.close(conn)
        {:error, :unavailable}
    end
  end

  defp path(%URI{path: path, query: query}) do
    case {path || "/", query} do
      {path, nil} -> path
      {path, query} -> path <> "?" <> query
    end
  end

  defp blank, do: %{status: nil, headers: [], body: ""}

  # The body keeps at most one byte past the limit. That byte signals the overflow to the caller.
  # The cut happens per chunk, because one read returns everything the socket buffered.
  #
  # Two timeouts, as the former pool had: one per read and one for the whole response.
  # The first stops a silent peer, the second a peer that sends data slowly without end.
  defp receive_response(conn, ref, limit, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      byte_size(acc.body) > limit -> {conn, {:ok, answer(acc)}}
      remaining <= 0 -> {conn, {:error, :unavailable}}
      true -> read(conn, ref, limit, deadline, acc, min(remaining, @read_timeout))
    end
  end

  defp read(conn, ref, limit, deadline, acc, timeout) do
    case Mint.HTTP.recv(conn, 0, timeout) do
      {:ok, conn, messages} ->
        case collect(messages, ref, limit, acc) do
          {:cont, acc} -> receive_response(conn, ref, limit, deadline, acc)
          {:done, acc} -> {conn, {:ok, answer(acc)}}
          :error -> {conn, {:error, :unavailable}}
        end

      {:error, conn, _reason, _responses} ->
        {conn, {:error, :unavailable}}
    end
  end

  defp collect([], _ref, _limit, acc), do: {:cont, acc}

  defp collect([message | rest], ref, limit, acc) do
    case message do
      # A status line starts a new response, so earlier data belonged to a previous one.
      # A peer may send a 1xx response such as 103 Early Hints first. Its `content-encoding`
      # does not apply to the final response.
      {:status, ^ref, status} ->
        collect(rest, ref, limit, %{blank() | status: status})

      {:headers, ^ref, headers} ->
        collect(rest, ref, limit, %{acc | headers: acc.headers ++ headers})

      {:data, ^ref, data} ->
        collect(rest, ref, limit, %{acc | body: acc.body <> cut(data, limit, acc.body)})

      {:done, ^ref} ->
        {:done, acc}

      {:error, ^ref, _reason} ->
        :error

      _other ->
        collect(rest, ref, limit, acc)
    end
  end

  defp cut(data, limit, body) do
    room = max(0, limit + 1 - byte_size(body))
    binary_part(data, 0, min(byte_size(data), room))
  end

  # Groups values by lowercased header name, because a peer may send one header several times.
  defp headers(sent) do
    Enum.reduce(sent, %{}, fn {name, value}, grouped ->
      Map.update(grouped, String.downcase(name), [value], &(&1 ++ [value]))
    end)
  end

  defp answer(acc), do: %{acc | headers: headers(acc.headers)}
end
