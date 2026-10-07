# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.LoggingTest do
  @moduledoc """
  What production writes to its log: one JSON object per line, and only the metadata Sikio names.
  """
  use ExUnit.Case, async: true

  alias Sikio.Logging

  # A key a caller passes by accident, such as a name, never reaches the line.
  test "a line is JSON and carries only the metadata Sikio allows" do
    {formatter, config} = Logging.formatter()

    event = %{
      level: :warning,
      msg: {:string, "feed refresh failed"},
      meta: %{time: System.os_time(:microsecond), feed_id: 7, username: "grace_hopper"}
    }

    line = event |> formatter.format(config) |> IO.iodata_to_binary()
    assert String.ends_with?(line, "\n")
    decoded = JSON.decode!(line)

    assert decoded["message"] == "feed refresh failed"
    assert decoded["severity"] == "warning"
    assert decoded["metadata"]["feed_id"] == 7
    refute line =~ "grace_hopper"
  end

  # Bandit logs a request that crashes with the connection attached, and the formatter would write
  # its path, the visitor's address and agent. A path may hold an invitation's token.
  test "a request that crashes reaches the line without its path, address or agent" do
    {formatter, config} = Logging.formatter()

    conn =
      Plug.Test.conn(:get, "/invite/a-secret-token")
      |> Plug.Conn.put_req_header("user-agent", "Probe/1")

    event = %{
      level: :error,
      msg: {:string, "request crashed"},
      meta: %{time: System.os_time(:microsecond), conn: conn}
    }

    line = event |> Logging.drop_request(nil) |> formatter.format(config) |> IO.iodata_to_binary()

    refute line =~ "a-secret-token"
    refute line =~ "Probe/1"
    refute line =~ "127.0.0.1"
  end

  # debug would turn on LiveView's and Ecto's own lines, with sessions and query parameters.
  test "the level comes from LOG_LEVEL, info unless it says otherwise, and never debug" do
    assert Logging.level(nil) == :info
    assert Logging.level("") == :info
    assert Logging.level("warning") == :warning
    assert Logging.level(" Warning ") == :warning
    assert Logging.level("ERROR") == :error
    assert_raise ArgumentError, fn -> Logging.level("debug") end
    assert_raise ArgumentError, fn -> Logging.level("loud") end
  end
end
