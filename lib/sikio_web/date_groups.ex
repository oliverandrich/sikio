# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.DateGroups do
  @moduledoc """
  Date groups for library lists: today, yesterday, this week, last week, then one per month.
  Entries without a date fall into an `:undated` group.

  Days are local to the reader. The browser sends its UTC offset as a connect param.
  Each date is shifted by that offset before its day is taken. Weeks start on Monday.
  """
  use Gettext, backend: SikioWeb.Gettext

  @doc """
  Returns the `{key, label}` group of `datetime` at `now`, for an offset in minutes ahead of UTC.

  The key identifies the group. The label is the displayed heading.
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
