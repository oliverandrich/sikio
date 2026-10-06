# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Transport do
  @moduledoc """
  One connection, one request, closed afterwards.

  This exists because of what pinning costs through a pool. Connecting to a checked address while
  the original name carries SNI and the certificate check means the name is part of the
  connection's options, and a pool is keyed by its options: `Req` hashes them into a module name,
  which interns an atom and starts a supervised `Finch` under it. Measured, twenty hostnames cost
  twenty supervision trees and a hundred and ninety atoms, and nothing gives either back. The
  atom table is capped, and running out of it kills the machine.

  A feed is asked once per interval, an hour by default, so a pool would have nothing to reuse.
  Opening a connection for the one request and closing it is both cheaper and bounded.

  Only HTTP/1 is spoken. A feed is one document, and the second protocol buys nothing here that
  would pay for its flow control.
  """
  @connect_timeout 5_000
  @read_timeout 10_000
  @response_timeout 15_000

  @doc """
  Fetches one document from an address that has already been checked.

  `uri` says what was asked for and `address` says where to go, which are deliberately not the
  same thing: the connection goes to the address that was checked, while the name in the uri
  still carries SNI and the certificate check.

  A plug may stand in for the peer, which is what every test in this application answers with.
  It belongs here because substituting a plug for a socket is this module's business. `plug:` is
  an option rather than only a setting so that the socket can be asked for by name, which is how
  the tests for this module reach it while the rest of the suite is answered by a stub.

  `cacerts:` replaces the system trust store. Only tests pass it, with a certificate authority
  they made themselves, so the certificate check can be asked of a real handshake.
  """
  def fetch(uri, address, headers, limit, opts \\ []) do
    case Keyword.get(opts, :plug, Application.get_env(:sikio, :feed_http_plug)) do
      nil -> connect(uri, address, headers, limit, opts)
      plug -> through(plug, pinned(uri, address), headers)
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
      {:ok, conn} -> request(conn, uri, headers, limit)
      {:error, _reason} -> {:error, :unavailable}
    end
  rescue
    # Connecting can raise rather than answer: a machine with no trust store for the system to
    # read makes Mint say so by throwing. That is a feed this host cannot fetch, which is what
    # the caller is told. Letting it through would end an Oban job with an exception, and the
    # rescue above it would call it an unsafe address, which is the wrong cause.
    _error -> {:error, :unavailable}
  end

  # The connection is built for the address the request would go to, carrying the headers it
  # would carry, so a stub may assert on the pinning without a socket being involved.
  #
  # Nothing here is rescued. A stub that raises is a test saying something, and the loudest
  # thing it says is that somebody forgot to register one: swallowing that would let such a
  # test read a plausible server failure and pass while proving nothing.
  defp through(plug, uri, headers) do
    {module, options} = if is_tuple(plug), do: plug, else: {plug, []}

    :get
    |> Plug.Test.conn(URI.to_string(uri))
    |> put_headers(headers)
    |> module.call(module.init(options))
    |> answered()
  end

  # Written onto the connection rather than through `put_req_header/3`, which refuses `host`: a
  # plug is being handed a request, not building one, and the host is what the pinning is about.
  defp put_headers(conn, headers) do
    sent = Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)
    %{conn | req_headers: conn.req_headers ++ sent}
  end

  # A plug that answers with the connection it was handed has sent nothing, and nothing is not
  # an empty document: reading a body off it would raise somewhere that reports an unsafe
  # address, which says the wrong thing about what happened.
  defp answered(%{status: nil}), do: {:error, :unavailable}

  defp answered(conn) do
    {:ok, %{status: conn.status, headers: headers(conn.resp_headers), body: conn.resp_body || ""}}
  end

  defp request(conn, uri, headers, limit) do
    case Mint.HTTP.request(conn, "GET", path(uri), headers, nil) do
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

  # One byte past the limit is kept and no more: that byte is what tells the caller it was
  # exceeded, and everything beyond it is memory nobody asked this to hold. The cut happens as
  # the bytes arrive, because a single read hands over everything the socket had buffered.
  #
  # Two budgets, as the pool had: how long one read may wait, and how long the whole answer has.
  # A peer that goes silent is refused by the first, one that trickles forever by the second.
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
      # A status line starts an answer, so everything gathered before it belonged to a previous
      # one. A peer may answer before it answers, and what an early hint said about compression
      # is not what the document it hints at is encoded with.
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

  # One entry per name holding every value sent under it, which is how a peer may send the same
  # header twice and mean both.
  defp headers(sent) do
    Enum.reduce(sent, %{}, fn {name, value}, grouped ->
      Map.update(grouped, String.downcase(name), [value], &(&1 ++ [value]))
    end)
  end

  defp answer(acc), do: %{acc | headers: headers(acc.headers)}
end
