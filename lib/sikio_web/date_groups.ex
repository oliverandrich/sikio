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

  @doc "Returns the reader's calendar date of `datetime`, for an offset in minutes ahead of UTC."
  def local_day(datetime, offset),
    do: datetime |> DateTime.add(offset, :minute) |> DateTime.to_date()

  @doc "Returns the label of the month that holds `date`, such as \"October 2026\"."
  def month(date), do: gettext("%{month} %{year}", month: month_name(date), year: date.year)

  @doc "Returns the label of `date` without its year, such as \"October 7\"."
  def day(date), do: gettext("%{month} %{day}", month: month_name(date), day: date.day)

  @doc "Returns the short weekday names from Monday to Sunday."
  def weekdays,
    do: [
      gettext("Mon"),
      gettext("Tue"),
      gettext("Wed"),
      gettext("Thu"),
      gettext("Fri"),
      gettext("Sat"),
      gettext("Sun")
    ]

  defp month_name(date) do
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
      date.month - 1
    )
  end
end
