# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ReloadGate do
  @moduledoc """
  Limits how many open pages reread their list at the same time.

  A library change reaches every open page of the account at once. Each page then rereads its
  list. The database pool drops checkouts that wait too long, and the page's process would crash.
  Pages wait here instead, in arrival order, without a timeout.

  It has one turn fewer than the pool has connections, so other requests still find one.
  """

  def child_spec(_opts) do
    pool = Keyword.get(Sikio.Repo.config(), :pool_size, 10)

    Supervisor.child_spec({Sikio.Turns, name: __MODULE__, limit: max(pool - 1, 1)},
      id: __MODULE__
    )
  end

  @doc "Runs `fun` once a turn is free and returns its result."
  def run(fun), do: Sikio.Turns.run(__MODULE__, fun)
end
