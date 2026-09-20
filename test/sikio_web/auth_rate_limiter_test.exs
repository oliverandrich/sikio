# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AuthRateLimiterTest do
  use ExUnit.Case, async: true
  alias Sikio.AuthRateLimiter

  setup do
    server = start_supervised!({AuthRateLimiter, name: SikioWeb.AuthRateLimiterTest})
    %{server: server}
  end

  test "concurrent callers share one limit, different keys do not", %{server: server} do
    results =
      1..20
      |> Task.async_stream(fn _ -> AuthRateLimiter.check(:one, 3, 60, server) end)
      |> Enum.to_list()

    assert Enum.count(results, &(&1 == {:ok, :ok})) == 3
    assert AuthRateLimiter.check(:two, 3, 60, server) == :ok
  end

  test "an expired window allows requests again", %{server: server} do
    assert AuthRateLimiter.check(:one, 1, 1, server) == :ok
    assert {:error, _seconds} = AuthRateLimiter.check(:one, 1, 1, server)
    Process.sleep(1100)
    assert AuthRateLimiter.check(:one, 1, 1, server) == :ok
  end
end
