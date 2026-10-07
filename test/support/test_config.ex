# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.TestConfig do
  @moduledoc """
  Changes application configuration for one test and restores it on exit.

  Restoring `nil` differs from leaving a key unset.
  A library rejects an explicit `nil` but applies its default for an absent key.
  This caused failures under two different keys, so the restore lives in one place.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Sets one rate-limit group's budget for the test and keeps the other groups.

  `:auth_rate_limits` is one keyword list for all groups.
  Overwriting it whole drops budgets set by another setup. Those groups fall back to defaults.
  This caused three failures in different files, each away from the faulty write.
  The group's counters are cleared as well.
  """
  def put_budget(group, budget) do
    configured = Application.get_env(:sikio, :auth_rate_limits, [])

    # The counters are keyed by account id.
    # SQLite rolls its id sequence back with each test's transaction.
    # A later test's account can therefore reuse an earlier test's id.
    :sys.replace_state(Sikio.AuthRateLimiter, &put_in(&1, [:groups, group], %{}))

    put_env(:sikio, :auth_rate_limits, Keyword.put(configured, group, budget))
  end

  @doc "Sets a key for the test. Restores the previous value on exit, or deletes a new key."
  def put_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, was} -> Application.put_env(app, key, was)
        :error -> Application.delete_env(app, key)
      end
    end)
  end
end
