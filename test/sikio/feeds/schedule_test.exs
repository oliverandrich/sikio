# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.ScheduleTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Sikio.Feeds.Schedule

  @now ~U[2026-10-06 12:00:00.000000Z]

  defp after_hours(newest_hours_ago, base_minutes \\ 60) do
    newest = newest_hours_ago && DateTime.add(@now, round(-newest_hours_ago * 3600), :second)

    @now
    |> Schedule.next_check(newest, base_minutes)
    |> DateTime.diff(@now, :minute)
    |> Kernel./(60)
  end

  # A tenth of the newest entry's age: asked often after it published, less often as it ages.
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

  # The operator's interval is the shortest wait. A day is the longest one only above it.
  test "a base interval longer than a day still holds" do
    assert after_hours(90 * 24, 48 * 60) == 48.0
  end

  # No date to judge by, or one a publisher set in the future, says nothing about the pace.
  test "a feed without a usable date is asked at the base interval" do
    assert after_hours(nil) == 1.0
    assert after_hours(-48) == 1.0
  end
end
