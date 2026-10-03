# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.DateGroupsTest do
  @moduledoc """
  The groups a library list falls into by date, seen from the reader's own day.
  """
  use ExUnit.Case, async: true

  alias SikioWeb.DateGroups

  # A Thursday. The week began on Monday the 28th of September.
  @now ~U[2026-10-01 10:00:00Z]

  defp group(datetime, offset \\ 0), do: DateGroups.group(datetime, @now, offset)

  test "the last days are named, older ones fall into their month" do
    assert group(~U[2026-10-01 06:00:00Z]) == {:today, "Today"}
    assert group(~U[2026-10-02 06:00:00Z]) == {:today, "Today"}, "a date ahead counts as today"
    assert group(~U[2026-09-30 23:00:00Z]) == {:yesterday, "Yesterday"}
    assert group(~U[2026-09-28 08:00:00Z]) == {:this_week, "This week"}
    assert group(~U[2026-09-27 08:00:00Z]) == {:last_week, "Last week"}
    assert group(~U[2026-09-21 00:00:00Z]) == {:last_week, "Last week"}
    assert group(~U[2026-09-20 23:59:59Z]) == {{2026, 9}, "September 2026"}
    assert group(~U[2025-12-24 12:00:00Z]) == {{2025, 12}, "December 2025"}
    assert group(nil) == {:undated, "No date"}
  end

  # The day turns at the reader's midnight, not at the server's.
  test "the reader's offset from UTC decides the day" do
    # 23:30 UTC on the 30th is already the 1st at UTC+2, and still the 30th at UTC.
    assert group(~U[2026-09-30 23:30:00Z], 120) == {:today, "Today"}
    assert group(~U[2026-09-30 23:30:00Z], 0) == {:yesterday, "Yesterday"}
    # Seen from UTC-10, the reader's own day is still the 30th: the 1st is ahead.
    assert DateGroups.group(~U[2026-09-30 12:00:00Z], ~U[2026-10-01 05:00:00Z], -600) ==
             {:today, "Today"}
  end

  # On a Monday, yesterday is the Sunday of last week; it is still called yesterday.
  test "yesterday stays yesterday across the start of a week" do
    monday = ~U[2026-09-28 10:00:00Z]
    assert DateGroups.group(~U[2026-09-27 10:00:00Z], monday, 0) == {:yesterday, "Yesterday"}
    assert DateGroups.group(~U[2026-09-26 10:00:00Z], monday, 0) == {:last_week, "Last week"}
  end
end
