# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Schedule do
  @moduledoc """
  When a feed is asked next: after a tenth of its newest entry's age.

  A show that published this morning is asked at the base interval, one that last published
  months ago once a day. The pace follows the feed without any history to keep.
  """

  @day_minutes 24 * 60

  @doc """
  The moment after `now` to ask a feed whose newest entry is dated `newest`.

  The wait is a tenth of that entry's age, at most a day and at least `base_minutes`. Without a
  date, or with one in the future, the feed is asked at the base interval. `wait` is what the
  server asked for, in seconds. It may lengthen the wait up to the cap, never shorten it.
  """
  def next_check(now, newest, base_minutes, wait \\ nil) do
    age = if newest, do: max(DateTime.diff(now, newest, :minute), 0), else: 0
    cap = max(@day_minutes, base_minutes)
    # The cap applies before the base, so an operator's interval above a day still holds.
    paced = age |> div(10) |> min(@day_minutes) |> max(base_minutes)
    asked = if wait, do: div(wait + 59, 60), else: 0
    DateTime.add(now, paced |> max(asked) |> min(cap), :minute)
  end

  @doc """
  Postpones `at` by a random part of its wait from `now`: up to a tenth, at most ten minutes.

  Feeds imported together would otherwise fall due together for good.
  """
  def spread(now, at) do
    most = at |> DateTime.diff(now, :second) |> div(10) |> min(600)
    if most > 0, do: DateTime.add(at, :rand.uniform(most + 1) - 1, :second), else: at
  end
end
