# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryLive.Calendar do
  @moduledoc """
  The history's month calendar. Days with heard items link to the history of that day.

  The selected day links back to the whole history, and so does the chip below the month.
  Up to three dots under a day show how many items were heard on it.
  """
  use SikioWeb, :html

  import SikioWeb.LibraryComponents, only: [segment: 1]

  alias SikioWeb.DateGroups
  alias SikioWeb.LibraryPaths

  attr :open, :boolean, required: true
  attr :month, Date, required: true, doc: "the first day of the shown month"
  attr :today, Date, required: true, doc: "the reader's date, the last month to show"
  attr :days, :map, required: true, doc: "heard items per date of the shown month"
  attr :filters, :map, required: true
  attr :titles, :map, required: true

  def calendar(assigns) do
    selected = if assigns.filters["day"] != "", do: Date.from_iso8601!(assigns.filters["day"])
    month = assigns.month

    assigns =
      assign(assigns,
        selected: selected,
        # Empty cells before the first: the grid starts on Monday.
        leading: Date.day_of_week(month) - 1,
        dates: Date.range(month, Date.end_of_month(month)),
        later?: Date.compare(month, Date.beginning_of_month(assigns.today)) == :lt
      )

    ~H"""
    <div id="history-calendar" hidden={!@open} class="px-6 pb-3 sm:px-12 lg:px-4">
      <div class="flex items-center justify-between">
        <button
          id="calendar-previous"
          type="button"
          phx-click="calendar_month"
          phx-value-step="-1"
          aria-label={gettext("Previous month")}
          title={gettext("Previous month")}
          class="flex size-9 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink"
        >
          <Lucideicons.chevron_left aria-hidden="true" class="size-4.5" />
        </button>
        <h2 id="calendar-month" aria-live="polite" class="text-label font-semibold">
          {DateGroups.month(@month)}
        </h2>
        <button
          :if={@later?}
          id="calendar-next"
          type="button"
          phx-click="calendar_month"
          phx-value-step="1"
          aria-label={gettext("Next month")}
          title={gettext("Next month")}
          class="flex size-9 items-center justify-center rounded-full text-muted hover:bg-ground hover:text-ink"
        >
          <Lucideicons.chevron_right aria-hidden="true" class="size-4.5" />
        </button>
        <span :if={!@later?} class="size-9" />
      </div>
      <div class="mt-1 grid grid-cols-7 gap-y-1 text-center">
        <span :for={name <- DateGroups.weekdays()} aria-hidden="true" class="text-meta text-muted">
          {name}
        </span>
        <span :for={_ <- 1..@leading//1} />
        <%= for date <- @dates do %>
          <%= case @days[date] do %>
            <% nil -> %>
              <span class="mx-auto flex size-9 items-center justify-center text-label text-muted">
                {date.day}
              </span>
            <% count -> %>
              <.link
                id={"calendar-day-#{date}"}
                patch={day_path(@filters, if(date != @selected, do: date), @titles)}
                aria-current={date == @selected && "date"}
                aria-label={
                  ngettext("%{day}, %{count} item", "%{day}, %{count} items", count,
                    day: DateGroups.day(date)
                  )
                }
                class="mx-auto flex size-9 flex-col items-center justify-center rounded-full text-label font-semibold text-ink hover:bg-ground aria-[current=date]:bg-accent aria-[current=date]:text-on-accent"
              >
                {date.day}
                <span aria-hidden="true" class="flex gap-0.5">
                  <span :for={_ <- 1..dots(count)} data-dot class="size-1 rounded-full bg-current" />
                </span>
              </.link>
          <% end %>
        <% end %>
      </div>
      <div :if={@selected} class="mt-2">
        <.segment id="calendar-clear" to={day_path(@filters, nil, @titles)} active>
          <span class="flex items-center gap-1.5">
            {DateGroups.day(@selected)}
            <Lucideicons.x aria-hidden="true" class="size-3.5" />
            <span class="sr-only">{gettext("Show all days")}</span>
          </span>
        </.segment>
      </div>
    </div>
    """
  end

  # One dot for one item, two for two or three, three from four on.
  defp dots(1), do: 1
  defp dots(count) when count <= 3, do: 2
  defp dots(_count), do: 3

  defp day_path(filters, date, titles),
    do: LibraryPaths.library_path(%{filters | "day" => to_string(date)}, nil, titles)
end
