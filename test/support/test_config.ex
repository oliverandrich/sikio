# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.TestConfig do
  @moduledoc """
  Application configuration a test changes, put back when the test ends.

  Writing `nil` back is not the same as leaving a key unset: a library reads that `nil` and
  refuses it, where an absent key is its own default. This example lost an afternoon to exactly
  that, twice, under two different keys, so the restore is written once and lives here.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]

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
