# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryLive.Rows do
  @moduledoc """
  The rows `SikioWeb.LibraryLive` loads: batches, a window around a deep link, and date groups.

  The functions take and return the socket. They read `:current_account`, `:filters` and
  `:selected`, and they write `:entries`, `:above` and `:more?`.
  `:above` is the entry right above the loaded rows, or nil when they start at the top.
  """
  import Phoenix.Component, only: [assign: 2]

  alias Sikio.Library
  alias SikioWeb.DateGroups

  # One batch fills the tallest screen, so `phx-viewport-bottom` loads the next before the end.
  @batch 25

  @doc """
  Rereads as many rows as are loaded, at least one batch, from where the window starts.
  The list does not shrink or jump under the scroll position.
  """
  def reread(socket) do
    %{current_account: account, filters: filters, entries: entries, above: above} = socket.assigns
    limit = max(length(entries), @batch)
    entries = Library.entries(account, filters, limit: limit, after: above)
    assign(socket, entries: entries, more?: length(entries) == limit)
  end

  @doc "Returns the rows to render: entries, with a heading where the date group changes."
  # Inserts a heading row wherever the date group of the sort date changes.
  # The queue is sorted by queue rank, so it has no headings.
  # A group that continues above a window keeps its heading there.
  # LiveView scrolls the old first row back into view after the batch above loads.
  # A heading on top would keep its place, and the list would jump.
  def grouped(entries, %{"status" => "queue"}, _offset, _above),
    do: Enum.map(entries, &{:entry, &1})

  def grouped(entries, filters, offset, above) do
    by = Library.sorted_by(filters)
    now = DateTime.utc_now()
    group = &(Library.sort_date(&1, by) |> DateGroups.group(now, offset))
    continued = above && elem(group.(above), 0)

    entries
    |> Enum.chunk_by(&elem(group.(&1), 0))
    |> Enum.flat_map(fn [first | _] = chunk ->
      {key, label} = group.(first)
      [{:heading, key, label} | Enum.map(chunk, &{:entry, &1})]
    end)
    |> case do
      [{:heading, ^continued, _label} | rows] -> rows
      rows -> rows
    end
  end

  @doc "Loads rows until the selected entry is among them, or a window around it."
  # An item opened by URL may lie beyond the loaded rows. The list then loads a window of a
  # batch above and below it, not every row above it. A list that sorts past the item's
  # position stays as it is. That covers filtered-out items.
  # The queue loads every row above instead, a choice for its usually short length.
  # Its drag and arrow keys send a row's index, which `Playback.move/3` takes as the position.
  def reach(%{assigns: %{selected: nil}} = socket), do: socket

  def reach(%{assigns: %{selected: selected, entries: entries, more?: more?}} = socket) do
    by = Library.sorted_by(socket.assigns.filters)

    cond do
      position(socket) || !more? ||
          (entries != [] and !Library.before?(List.last(entries), selected, by)) ->
        socket

      by == :queue ->
        socket |> load_more() |> reach()

      true ->
        window(socket, selected)
    end
  end

  # The rows after the last one above `selected` start with `selected` itself, if it is listed.
  defp window(socket, selected) do
    {above, rows} = batch_above(socket, selected)
    %{current_account: account, filters: filters} = socket.assigns
    below = Library.entries(account, filters, limit: @batch, after: List.last(rows) || above)
    assign(socket, entries: rows ++ below, above: above, more?: length(below) == @batch)
  end

  # Reads a batch and one more above `entry`. The first stays unloaded and marks where the
  # window starts. `nil` means the window starts at the top of the list.
  defp batch_above(socket, entry) do
    %{current_account: account, filters: filters} = socket.assigns

    case Library.entries(account, filters, limit: @batch + 1, before: entry) do
      [above | rows] = entries when length(entries) > @batch -> {above, rows}
      entries -> {nil, entries}
    end
  end

  @doc "Returns the selected entry's index among the loaded rows, or nil."
  def position(%{assigns: %{selected: nil}}), do: nil

  def position(%{assigns: %{selected: selected, entries: entries}}),
    do: Enum.find_index(entries, &(&1.id == selected.id))

  @doc "Appends the next batch after the last loaded row."
  # Infinite scroll: appends the next batch after the last loaded entry. There is no pagination.
  def load_more(%{assigns: %{more?: false}} = socket), do: socket

  def load_more(socket) do
    %{current_account: account, filters: filters, entries: entries} = socket.assigns
    batch = Library.entries(account, filters, limit: @batch, after: List.last(entries))
    assign(socket, entries: entries ++ batch, more?: length(batch) == @batch)
  end

  @doc "Loads the batch past the edge that the key `key` moves beyond."
  # `j` on the last loaded row loads the next batch first, `k` on the first the one above.
  def extend(socket, key) do
    case {key, position(socket)} do
      {"k", 0} -> load_less(socket)
      {"j", last} when last == length(socket.assigns.entries) - 1 -> load_more(socket)
      _ -> socket
    end
  end

  @doc "Prepends the batch above the loaded rows."
  # A window opened deep in the list grows upwards by a batch when its top comes into view.
  def load_less(%{assigns: %{above: nil}} = socket), do: socket

  def load_less(%{assigns: %{entries: [first | _] = entries}} = socket) do
    {above, batch} = batch_above(socket, first)
    assign(socket, entries: batch ++ entries, above: above)
  end
end
