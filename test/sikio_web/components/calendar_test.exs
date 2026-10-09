# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryLive.CalendarTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias SikioWeb.LibraryLive.Calendar

  @filters %{
    "status" => "heard",
    "source" => "",
    "tag" => "",
    "q" => "",
    "day" => "",
    "offset" => 0
  }

  # One dot for one item, two for two or three, three from four on.
  test "a day's dots grow with the items heard on it" do
    days = %{~D[2026-10-01] => 1, ~D[2026-10-02] => 2, ~D[2026-10-03] => 3, ~D[2026-10-04] => 4}

    html =
      render_component(&Calendar.calendar/1,
        open: true,
        month: ~D[2026-10-01],
        today: ~D[2026-10-09],
        days: Map.put(days, ~D[2026-10-05], 12),
        filters: @filters,
        titles: %{}
      )
      |> LazyHTML.from_fragment()

    dots = fn day -> html |> LazyHTML.query("#calendar-day-#{day} [data-dot]") |> Enum.count() end

    assert Enum.map(1..5, &dots.(Date.new!(2026, 10, &1))) == [1, 2, 2, 3, 3]
  end
end
