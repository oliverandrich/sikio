# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.TransportTest do
  @moduledoc """
  Tests `Sikio.Feeds.Transport` over real sockets against a loopback server with fixed responses.

  Other tests stop at the Req.Test plug and never reach this module. A loopback listener needs no
  DNS or external server. This layer sits below the address checks, so it accepts 127.0.0.1.
  """
  use ExUnit.Case, async: true

  require Record

  alias Sikio.Feeds.Transport

  @listen [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  # Sends a raw response, so a test can produce responses that no HTTP library would emit.
  defp answering(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, @listen)

    {:ok, port} = :inet.port(listener)
    owner = self()

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener, 5_000)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
      send(owner, {:asked, request})
      :gen_tcp.send(socket, response)
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    port
  end

  # The URI host and the connect address differ on purpose. Transport connects to the address.
  defp fetch(port, opts \\ []) do
    scheme = if opts[:cacerts], do: "https", else: "http"
    uri = %URI{scheme: scheme, host: "feeds.example.org", port: port, path: "/rss"}
    headers = [{"host", uri.host}, {"accept-encoding", "identity"}]
    limit = Keyword.get(opts, :limit, 8_000_000)

    # `plug: nil` overrides `:feed_http_plug`, so the request uses a real socket.
    Transport.fetch(
      uri,
      {127, 0, 0, 1},
      headers,
      limit,
      [plug: nil] ++ Keyword.take(opts, [:cacerts])
    )
  end

  test "a document arrives with its status, its headers and its body" do
    port =
      answering("""
      HTTP/1.1 200 OK\r
      Content-Type: application/xml\r
      ETag: "abc"\r
      Content-Length: 5\r
      \r
      hello\
      """)

    assert {:ok, response} = fetch(port)
    assert response.status == 200
    assert response.body == "hello"
    assert response.headers["etag"] == ["\"abc\""]
  end

  # Transport connects to the checked address and sends the URI host in the `host` header.
  # The test reads the header from the raw request.
  test "the name the caller gave is what reaches the peer" do
    port = answering("HTTP/1.1 204 No Content\r\n\r\n")

    assert {:ok, %{status: 204}} = fetch(port)
    assert_received {:asked, request}
    assert request =~ "host: feeds.example.org"
  end

  # A server may send a 1xx response before the final one. Its headers must be discarded.
  # A merged `content-encoding` header would make a valid feed fail to decode.
  test "an informational answer is not mixed into the real one" do
    port =
      answering("""
      HTTP/1.1 103 Early Hints\r
      Content-Encoding: gzip\r
      Link: </style.css>; rel=preload\r
      \r
      HTTP/1.1 200 OK\r
      Content-Length: 5\r
      \r
      plain\
      """)

    assert {:ok, response} = fetch(port)
    assert response.status == 200
    assert response.body == "plain"
    assert Map.get(response.headers, "content-encoding") == nil
    assert Map.get(response.headers, "link") == nil
  end

  # One byte past the limit signals the overflow to the caller. The body is truncated there.
  test "a body larger than the limit is kept only one byte past it" do
    body = String.duplicate("x", 200_000)

    port =
      answering("HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <> body)

    assert {:ok, response} = fetch(port, limit: 1_000)
    assert byte_size(response.body) == 1_001
  end

  # Certificate verification uses the URI host, not the connect address.
  # The test generates a CA and a server certificate and passes the CA as `cacerts`.
  test "a certificate for the name in the uri is accepted at the checked address" do
    {port, cacerts} = answering_tls("feeds.example.org")

    assert {:ok, %{status: 204}} = fetch(port, cacerts: cacerts)
  end

  test "a certificate for another name is refused" do
    {port, cacerts} = answering_tls("other.example.org")

    assert {:error, :unavailable} = fetch(port, cacerts: cacerts)
  end

  defp answering_tls(name) do
    san = extension(extnID: {2, 5, 29, 17}, critical: false, extnValue: [dNSName: ~c"#{name}"])
    # Signed with SHA-256. The default SHA-1 is rejected by TLS 1.3 clients.
    key = [key: {:namedCurve, :secp256r1}, digest: :sha256]

    %{cert: cert, key: private, cacerts: cacerts} =
      %{root: key, peer: [extensions: [san]] ++ key}
      |> :public_key.pkix_test_data()
      |> Map.new()

    {:ok, listener} = :ssl.listen(0, @listen ++ [cert: cert, key: private])

    {:ok, {_ip, port}} = :ssl.sockname(listener)

    spawn_link(fn ->
      {:ok, socket} = :ssl.transport_accept(listener, 5_000)

      with {:ok, socket} <- :ssl.handshake(socket, 5_000),
           {:ok, _request} <- :ssl.recv(socket, 0, 5_000) do
        :ssl.send(socket, "HTTP/1.1 204 No Content\r\n\r\n")
        :ssl.close(socket)
      end

      :ssl.close(listener)
    end)

    {port, cacerts}
  end
end
