# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.HTTPTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Sikio.Feeds.HTTP

  test "pins the checked address while keeping the original host for HTTP and TLS" do
    Req.Test.stub(HTTP, fn conn ->
      assert conn.host == "93.184.216.34"
      assert Plug.Conn.get_req_header(conn, "host") == ["feeds.example.org"]
      Plug.Conn.send_resp(conn, 200, "hello")
    end)

    assert {:ok, %{body: "hello", url: "https://feeds.example.org/rss"}} =
             HTTP.get("https://feeds.example.org/rss")
  end

  test "rejects private and special-use destinations before requesting" do
    for ip <- [
          {127, 0, 0, 1},
          {10, 1, 2, 3},
          {100, 64, 0, 1},
          {169, 254, 169, 254},
          {192, 168, 1, 1},
          {172, 31, 0, 1},
          {0, 0, 0, 0},
          {224, 1, 1, 1},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 65_535, 32_512, 1},
          {0x2002, 0x7F00, 1, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1}
        ] do
      refute HTTP.public_address?(ip), inspect(ip)
    end

    for url <- [
          "http://127.0.0.1/",
          "http://169.254.169.254/latest/",
          "ftp://example.org/",
          "http://user:pass@example.org/",
          "https://example.org:5432/"
        ] do
      assert {:error, :unsafe_url} = HTTP.get(url)
    end
  end

  test "refuses oversized URLs before they can reach the database index" do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, "unexpected") end)

    assert {:error, :unsafe_url} =
             HTTP.get("https://example.org/" <> String.duplicate("a", 2_500))
  end

  test "checks redirect destinations and limits loops" do
    Req.Test.stub(HTTP, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:error, :unsafe_url} = HTTP.get("https://example.org/")

    Req.Test.stub(HTTP, fn conn ->
      conn |> Plug.Conn.put_resp_header("location", "/again") |> Plug.Conn.send_resp(301, "")
    end)

    assert {:error, :too_many_redirects} = HTTP.get("https://example.org/")
  end

  test "follows relative redirects and enforces the byte limit" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/start" ->
          conn |> Plug.Conn.put_resp_header("location", "/rss") |> Plug.Conn.send_resp(302, "")

        "/rss" ->
          Plug.Conn.send_resp(conn, 200, "hello")
      end
    end)

    assert {:ok, %{url: "https://example.org/rss"}} = HTTP.get("https://example.org/start")
    assert {:error, :too_large} = HTTP.get("https://example.org/rss", max_bytes: 4)
  end

  # A stub that returns the conn unchanged sends no response. Status and body are then nil.
  # Without handling, the nil body raised an error that was reported as `:unsafe_url`.
  test "a stub that never answers is reported as unavailable, not as an unsafe address" do
    Req.Test.stub(HTTP, fn conn -> conn end)

    assert {:error, :unavailable} = HTTP.get("https://feeds.example.org/rss")
  end

  # Every request goes through Req.Test, so no test reaches the network.
  # A missing stub must raise. An `:unavailable` result could let a test pass without a stub.
  test "a request with no stub registered fails loudly rather than looking unavailable" do
    assert_raise RuntimeError, ~r/stub/, fn ->
      HTTP.get("https://nobody-stubbed-this.example.org/rss")
    end
  end
end
