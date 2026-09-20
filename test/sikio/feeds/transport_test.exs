# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.TransportTest do
  @moduledoc """
  The socket, against a server that answers exactly what these tests dictate.

  Everything else in the suite stops at the plug that stands in for a peer, so nothing there
  reaches this module at all. A listener on the loopback is neither DNS nor a stranger's server,
  and this is the layer beneath the address checks, so it may be handed one directly.
  """
  use ExUnit.Case, async: true

  alias Sikio.Feeds.Transport

  # What a peer would send, byte for byte, so a test may describe a shape no library would emit.
  defp answering(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

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

  # The uri names what was asked for, the address says where to go. Here they disagree on
  # purpose, which is the whole shape this module exists for.
  defp fetch(port, limit \\ 8_000_000) do
    uri = %URI{scheme: "http", host: "feeds.example.org", port: port, path: "/rss"}
    headers = [{"host", uri.host}, {"accept-encoding", "identity"}]

    # No stand-in: this is the socket, which is the only thing these tests are about.
    Transport.fetch(uri, {127, 0, 0, 1}, headers, limit, nil)
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

  # The connection goes to a checked address while the name it claims rides in the header. That
  # is the whole reason this module exists, so it is asked of the wire rather than of the code.
  test "the name the caller gave is what reaches the peer" do
    port = answering("HTTP/1.1 204 No Content\r\n\r\n")

    assert {:ok, %{status: 204}} = fetch(port)
    assert_received {:asked, request}
    assert request =~ "host: feeds.example.org"
  end

  # A peer may answer before it answers. Those headers belong to nothing: taking them for the
  # real ones turns an early hint about compression into a refusal of a perfectly good feed.
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

  # One byte past the limit is what tells the caller it was exceeded. Everything beyond that is
  # memory this process was not asked to hold.
  test "a body larger than the limit is kept only one byte past it" do
    body = String.duplicate("x", 200_000)

    port =
      answering("HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <> body)

    assert {:ok, response} = fetch(port, 1_000)
    assert byte_size(response.body) == 1_001
  end
end
