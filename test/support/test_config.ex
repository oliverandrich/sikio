# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.TestConfig do
  @moduledoc """
  Application configuration a test changes, put back when the test ends.

  Writing `nil` back is not the same as leaving a key unset: a library reads that `nil` and
  refuses it, where an absent key is its own default. This example lost an afternoon to exactly
  that, twice, under two different keys, so the restore is written once and lives here.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Sets one rate-limit budget for the length of the test, leaving every other group standing.

  `:auth_rate_limits` is one keyword list holding all of them, so writing it whole is how a test
  quietly takes away a budget that somebody else's setup put there — and the group then falls
  back to its shipped default rather than to what was wanted. That has cost this suite three
  separate failures, each in a different file and none of them where the mistake was made.
  The group's counts are cleared as well.
  """
  def put_budget(group, budget) do
    configured = Application.get_env(:sikio, :auth_rate_limits, [])

    # The counts start empty. They are kept per account id, and SQLite rolls its id sequence back
    # with each test's transaction, so a later test's account may carry an earlier one's id.
    :sys.replace_state(Sikio.AuthRateLimiter, &put_in(&1, [:groups, group], %{}))

    put_env(:sikio, :auth_rate_limits, Keyword.put(configured, group, budget))
  end

  @doc "Sets a key for the length of the test and restores what was there, absence included."
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
