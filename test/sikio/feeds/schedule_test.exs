# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.ScheduleTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Sikio.Feeds.Schedule

  @now ~U[2026-10-06 12:00:00.000000Z]

  defp after_hours(newest_hours_ago, base_minutes \\ 60, wait \\ nil) do
    newest = newest_hours_ago && DateTime.add(@now, round(-newest_hours_ago * 3600), :second)

    @now
    |> Schedule.next_check(newest, base_minutes, wait)
    |> DateTime.diff(@now, :minute)
    |> Kernel./(60)
  end

  # The interval is a tenth of the newest entry's age, so active feeds are checked more often.
  test "a feed is asked after a tenth of its newest entry's age" do
    assert after_hours(4 * 24) == 9.6
    assert after_hours(48) == 4.8
  end

  test "never more often than the base interval" do
    assert after_hours(10) == 1.0
    assert after_hours(10, 90) == 1.5
  end

  test "at least once a day, however quiet the feed" do
    assert after_hours(90 * 24) == 24.0
  end

  # The base interval is the minimum. The one-day maximum applies only when it exceeds the base.
  test "a base interval longer than a day still holds" do
    assert after_hours(90 * 24, 48 * 60) == 48.0
  end

  # A missing or future publication date falls back to the base interval.
  test "a feed without a usable date is asked at the base interval" do
    assert after_hours(nil) == 1.0
    assert after_hours(-48) == 1.0
  end

  # The server's wait, in seconds, can only lengthen the interval, up to the cap.
  test "the server may ask for a longer wait, not a shorter one" do
    assert after_hours(10, 60, 3 * 3600) == 3.0
    assert after_hours(4 * 24, 60, 60) == 9.6
    assert after_hours(10, 60, 7 * 24 * 3600) == 24.0
    assert after_hours(10, 48 * 60, 7 * 24 * 3600) == 48.0
  end

  # Feeds imported together would otherwise stay synchronized. `spread/2` adds a random delay of
  # up to a tenth of the wait, capped at ten minutes. It never moves a check earlier.
  test "spreading adds up to a tenth of the wait, at most ten minutes" do
    spread = fn minutes ->
      at = DateTime.add(@now, minutes, :minute)
      for _ <- 1..200, do: @now |> Schedule.spread(at) |> DateTime.diff(at, :second)
    end

    hour = spread.(60)
    assert Enum.min(hour) >= 0 and Enum.max(hour) <= 6 * 60
    assert length(Enum.uniq(hour)) > 1

    day = spread.(24 * 60)
    assert Enum.max(day) <= 10 * 60
  end
end
