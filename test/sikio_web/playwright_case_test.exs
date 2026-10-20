# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlaywrightCaseTest do
  # The budgets and counters are global, so this test cannot share them with others.
  use ExUnit.Case, async: false

  alias Sikio.Accounts.User
  alias Sikio.AuthRateLimiter
  alias SikioWeb.AuthRateLimit

  setup do
    SikioWeb.PlaywrightCase.room_for_the_suites_own_codes()
    :ok
  end

  # Every browser request comes from loopback, so the features share one recovery counter.
  # Under the default budget of ten a minute, a repeated feature run got 429 on `/auth/recovery`.
  test "the suite's budgets leave room for more than ten recovery codes a minute" do
    key = AuthRateLimit.key(%Plug.Conn{remote_ip: {127, 0, 0, 1}}, :recovery)
    assert spend(:recovery, key, 11) == :ok
  end

  # SQLite reuses account ids across tests, so the features share one invitation counter too.
  # Under the default budget of twenty a day, a repeated feature run stopped issuing links.
  test "the suite's budgets leave room for more than twenty invitations a day" do
    key = AuthRateLimit.key(%User{id: 1}, :invite)
    assert spend(:invite, key, 21) == :ok
  end

  defp spend(group, key, times) do
    {limit, seconds} = AuthRateLimiter.budget(group)
    Enum.find(1..times, :ok, fn _ -> AuthRateLimiter.check(key, limit, seconds) != :ok end)
  end
end
