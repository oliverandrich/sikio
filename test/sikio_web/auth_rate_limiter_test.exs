# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AuthRateLimiterTest do
  use ExUnit.Case, async: true
  alias Sikio.AuthRateLimiter

  setup do
    server = start_supervised!({AuthRateLimiter, name: SikioWeb.AuthRateLimiterTest, capacity: 2})
    %{server: server}
  end

  test "concurrent callers share one limit, different keys do not", %{server: server} do
    results =
      1..20
      |> Task.async_stream(fn _ -> AuthRateLimiter.check({:one, 1}, 3, 60, server) end)
      |> Enum.to_list()

    assert Enum.count(results, &(&1 == {:ok, :ok})) == 3
    assert AuthRateLimiter.check({:two, 1}, 3, 60, server) == :ok
  end

  test "an expired window allows requests again", %{server: server} do
    assert AuthRateLimiter.check({:one, 1}, 1, 1, server) == :ok
    assert {:error, _seconds} = AuthRateLimiter.check({:one, 1}, 1, 1, server)
    Process.sleep(1100)
    assert AuthRateLimiter.check({:one, 1}, 1, 1, server) == :ok
  end

  # A full table refuses a new key. The retry time is when the earliest slot frees.
  # Returning the requested window would block a day-long budget for a day.
  test "a full group refuses until its earliest slot frees", %{server: server} do
    assert AuthRateLimiter.check({:ceremony, 1}, 5, 60, server) == :ok
    assert AuthRateLimiter.check({:ceremony, 2}, 5, 60, server) == :ok

    assert {:error, seconds} = AuthRateLimiter.check({:ceremony, 3}, 5, 86_400, server)
    assert seconds in 1..60
  end

  test "a flood of one group leaves room in another", %{server: server} do
    assert AuthRateLimiter.check({:ceremony, 1}, 5, 60, server) == :ok
    assert AuthRateLimiter.check({:ceremony, 2}, 5, 60, server) == :ok

    assert AuthRateLimiter.check({:invite, 7}, 20, 86_400, server) == :ok
  end
end
