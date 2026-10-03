# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.DateGroups do
  @moduledoc """
  The groups a library list falls into by date: today, yesterday, this week, last week, then
  one per month, and the undated last.

  Days are the reader's own. The browser sends its offset from UTC when it connects, and a date
  is moved by it before its day is read. Weeks begin on Monday.
  """
  use Gettext, backend: SikioWeb.Gettext

  @doc """
  The group `datetime` falls into, seen at `now` by a reader `offset` minutes ahead of UTC:
  `{key, label}`, where the key tells two groups apart and the label names one.
  """
  def group(nil, _now, _offset), do: {:undated, gettext("No date")}

  def group(datetime, now, offset) do
    day = local_day(datetime, offset)
    today = local_day(now, offset)
    week = Date.beginning_of_week(today, :monday)

    cond do
      Date.compare(day, today) != :lt -> {:today, gettext("Today")}
      Date.diff(today, day) == 1 -> {:yesterday, gettext("Yesterday")}
      Date.compare(day, week) != :lt -> {:this_week, gettext("This week")}
      Date.diff(week, day) <= 7 -> {:last_week, gettext("Last week")}
      true -> {{day.year, day.month}, month(day)}
    end
  end

  defp local_day(datetime, offset),
    do: datetime |> DateTime.add(offset, :minute) |> DateTime.to_date()

  defp month(day) do
    name =
      Enum.at(
        [
          gettext("January"),
          gettext("February"),
          gettext("March"),
          gettext("April"),
          gettext("May"),
          gettext("June"),
          gettext("July"),
          gettext("August"),
          gettext("September"),
          gettext("October"),
          gettext("November"),
          gettext("December")
        ],
        day.month - 1
      )

    gettext("%{month} %{year}", month: name, year: day.year)
  end
end
