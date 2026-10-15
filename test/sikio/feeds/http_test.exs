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

  # A host may list an address that refuses connections. The next checked address serves it.
  test "tries the next address when one refuses the connection" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.host do
        "93.184.216.35" -> Req.Test.transport_error(conn, :econnrefused)
        "93.184.216.34" -> Plug.Conn.send_resp(conn, 200, "second")
      end
    end)

    assert {:ok, %{body: "second"}} = HTTP.get("https://two-addresses.example.org/rss")

    Req.Test.stub(HTTP, &Req.Test.transport_error(&1, :econnrefused))
    assert {:error, :unavailable} = HTTP.get("https://two-addresses.example.org/rss")
  end

  # The stub stands for the peer, so it keeps the deadline a real socket would.
  test "a stub that does not answer ends at the given timeout" do
    Req.Test.stub(HTTP, fn conn -> receive do: (:never -> conn) end)

    {elapsed, result} =
      :timer.tc(fn -> HTTP.get("https://feeds.example.org/rss", timeout: 100) end, :millisecond)

    assert result == {:error, :unavailable}
    assert elapsed < 2_000
  end

  # The timeout bounds the whole lookup. A redirect does not start a fresh one.
  test "redirects share one timeout" do
    Req.Test.stub(HTTP, fn conn ->
      # Each hop is slow but within the timeout on its own.
      Process.sleep(150)

      case conn.request_path do
        "/a" ->
          conn |> Plug.Conn.put_resp_header("location", "/b") |> Plug.Conn.send_resp(302, "")

        "/b" ->
          Plug.Conn.send_resp(conn, 200, "late")
      end
    end)

    assert {:error, :unavailable} = HTTP.get("https://feeds.example.org/a", timeout: 250)
  end

  # A stub that exits stands for a test mistake, so the caller exits with the same reason.
  test "a stub's exit reaches the caller unchanged" do
    Req.Test.stub(HTTP, fn _conn -> exit(:stub_gave_up) end)
    assert catch_exit(HTTP.get("https://feeds.example.org/rss")) == :stub_gave_up
  end

  # A timeout costs the whole connect timeout. Trying every address would multiply it.
  test "gives up after a timeout instead of trying the next address" do
    Req.Test.stub(HTTP, fn conn ->
      case conn.host do
        "93.184.216.35" -> Req.Test.transport_error(conn, :timeout)
        "93.184.216.34" -> Plug.Conn.send_resp(conn, 200, "second")
      end
    end)

    assert {:error, :unavailable} = HTTP.get("https://two-addresses.example.org/rss")
  end

  # A hub subscription is a form POST to a checked address.
  # It follows no redirect, which would resend the form elsewhere.
  test "posts a form to the checked address and follows no redirect" do
    Req.Test.stub(HTTP, fn conn ->
      assert conn.method == "POST"
      assert conn.host == "93.184.216.34"

      assert Plug.Conn.get_req_header(conn, "content-type") == [
               "application/x-www-form-urlencoded"
             ]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body) == %{"hub.mode" => "subscribe"}

      conn
      |> Plug.Conn.put_resp_header("location", "https://elsewhere.example.org/")
      |> Plug.Conn.send_resp(302, "")
    end)

    assert {:ok, %{status: 302}} =
             HTTP.post("https://feeds.example.org/subscribe", %{"hub.mode" => "subscribe"})

    assert {:error, :unsafe_url} = HTTP.post("http://127.0.0.1/", %{})
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
