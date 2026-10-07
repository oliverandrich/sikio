# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Schedule do
  @moduledoc """
  Computes a feed's next check time: a tenth of its newest entry's age.

  A feed that published this morning is checked at the base interval. One that last published
  months ago is checked once a day. No polling history is stored.
  """

  @day_minutes 24 * 60

  @doc """
  Returns the next check time after `now` for a feed whose newest entry is dated `newest`.

  The delay is a tenth of that entry's age, at most a day and at least `base_minutes`.
  Without a date, or with a future date, the delay is `base_minutes`. `wait` is the server's
  requested delay in seconds. It can extend the delay up to the cap, never shorten it.
  """
  def next_check(now, newest, base_minutes, wait \\ nil) do
    age = if newest, do: max(DateTime.diff(now, newest, :minute), 0), else: 0
    cap = max(@day_minutes, base_minutes)

    # The day cap applies before the base minimum, so an operator interval above a day holds.
    paced = age |> div(10) |> min(@day_minutes) |> max(base_minutes)
    asked = if wait, do: div(wait + 59, 60), else: 0
    DateTime.add(now, paced |> max(asked) |> min(cap), :minute)
  end

  @doc """
  Delays `at` by a random jitter of up to a tenth of its distance from `now`, at most ten minutes.

  Without jitter, feeds imported together would stay due at the same time.
  """
  def spread(now, at) do
    most = at |> DateTime.diff(now, :second) |> div(10) |> min(600)
    if most > 0, do: DateTime.add(at, :rand.uniform(most + 1) - 1, :second), else: at
  end
end
