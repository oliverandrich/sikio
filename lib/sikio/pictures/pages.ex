# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Pictures.Pages do
  @moduledoc """
  Lets at most four web pages be read for their pictures at once, across all requests.

  A list of new Mediathek programmes asks one broadcaster for many pages. The limit keeps that a
  trickle. The page is read in the caller's process; `Sikio.Turns` only grants turns.
  """
  @limit 4

  def child_spec(_opts),
    do: Supervisor.child_spec({Sikio.Turns, name: __MODULE__, limit: @limit}, id: __MODULE__)

  @doc "Runs `fun` once a turn is free and returns its result."
  def run(fun), do: Sikio.Turns.run(__MODULE__, fun)
end
