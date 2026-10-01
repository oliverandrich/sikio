# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MediaComponents do
  @moduledoc """
  Shared playback labels and time formatting.

  Watched or listened depends on what the thing is, so the wording is decided here rather than in
  three templates that would drift apart.
  """
  use Gettext, backend: SikioWeb.Gettext

  @doc "Whether this is something somebody watches. Two of the three kinds are."
  def video?(%{feed: %{kind: kind}}), do: kind in [:youtube, :peertube]

  @doc "What a source is, in one word, for a list that shows all three kinds together."
  def source_label(%{kind: :youtube}), do: gettext("YouTube")
  def source_label(%{kind: :peertube}), do: gettext("PeerTube")
  def source_label(%{kind: :podcast}), do: gettext("Podcast")

  @doc """
  What pressing play hands your connection to.

  Each kind reaches a different stranger, and saying which is the point of the sentence.
  """
  def privacy_note(%{feed: %{kind: :youtube}}),
    do:
      gettext(
        "Loads the YouTube player. YouTube receives your connection data when you press Play."
      )

  def privacy_note(%{feed: %{kind: :peertube}} = entry),
    do:
      gettext(
        "Plays through %{host}, the instance holding this video. Your place is saved in Sikio.",
        host: URI.parse(entry.embed_url || "").host || gettext("the instance")
      )

  def privacy_note(_entry),
    do:
      gettext("Audio streams directly from the podcast publisher. Your place is saved in Sikio.")

  def status(%{playback: nil}), do: :new
  def status(%{playback: state}), do: state.status

  def status_label(entry) do
    case status(entry) do
      :new ->
        gettext("New")

      :in_progress ->
        gettext("In progress")

      :completed ->
        if video?(entry), do: gettext("Watched"), else: gettext("Listened")
    end
  end

  def play_label(%{playback: %{status: :completed}}), do: gettext("Play again")
  def play_label(%{playback: %{position: position}}) when position > 0, do: gettext("Resume")
  def play_label(_entry), do: gettext("Play")

  def mark_done_label(entry),
    do: if(video?(entry), do: gettext("Mark as watched"), else: gettext("Mark as listened"))

  def mark_new_label(entry),
    do: if(video?(entry), do: gettext("Mark as unwatched"), else: gettext("Mark as unlistened"))

  def kind_label(%{feed: %{kind: :youtube}}), do: gettext("YouTube video")
  def kind_label(%{feed: %{kind: :peertube}}), do: gettext("PeerTube video")
  def kind_label(_entry), do: gettext("Podcast episode")

  def timestamp(seconds) do
    seconds = trunc(seconds || 0)
    minutes = div(seconds, 60)
    "#{minutes}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "A stated runtime as a list shows it: hours only when there are any, `nil` when unknown."
  def runtime(nil), do: nil
  def runtime(seconds) when seconds < 3600, do: timestamp(seconds)

  def runtime(seconds),
    do: "#{div(seconds, 3600)}:" <> String.pad_leading(timestamp(rem(seconds, 3600)), 5, "0")

  @doc "The library's views by status: the filter value, the count's key and the name."
  def views do
    [
      {"", :all, gettext("All items")},
      {"new", :new, gettext("New")},
      {"in_progress", :in_progress, gettext("In progress")},
      {"completed", :completed, gettext("Completed")}
    ]
  end

  @doc "A day as a list and a heading show it, with the month in the reader's language."
  def date(datetime) do
    month = Enum.at(months(), datetime.month - 1)
    gettext("%{day} %{month} %{year}", day: datetime.day, month: month, year: datetime.year)
  end

  defp months do
    [
      gettext("Jan"),
      gettext("Feb"),
      gettext("Mar"),
      gettext("Apr"),
      gettext("May"),
      gettext("Jun"),
      gettext("Jul"),
      gettext("Aug"),
      gettext("Sep"),
      gettext("Oct"),
      gettext("Nov"),
      gettext("Dec")
    ]
  end
end
