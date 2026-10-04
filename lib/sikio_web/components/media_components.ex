# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MediaComponents do
  @moduledoc """
  Shared playback labels, time formatting and the views' icons.

  Watched or listened depends on what the thing is, so the wording is decided here rather than in
  three templates that would drift apart.
  """
  use Phoenix.Component
  use Gettext, backend: SikioWeb.Gettext
  use SikioWeb, :verified_routes

  @doc """
  A source's name as the reader calls it: the subscription's own name, or the feed's title. An
  entry carries the name its account gives the source.
  """
  def source_name(%Sikio.Library.Subscription{name: name, feed: feed}), do: name || feed.title
  def source_name(%{source_name: name}) when is_binary(name), do: name
  def source_name(%{feed: feed}), do: feed.title

  @doc "Whether this is something somebody watches. Two of the three kinds are."
  def video?(%{feed: %{kind: kind}}), do: kind in [:youtube, :peertube]

  @doc "What a source is, in one word, for a list that shows all three kinds together."
  def source_label(%{kind: :youtube}), do: gettext("YouTube")
  def source_label(%{kind: :peertube}), do: gettext("PeerTube")
  def source_label(%{kind: :podcast}), do: gettext("Podcast")

  def status(%{playback: nil}), do: :new
  def status(%{playback: state}), do: state.status

  def status_label(entry) do
    case status(entry) do
      :new ->
        gettext("New")

      :in_progress ->
        gettext("In progress")

      :heard ->
        if video?(entry), do: gettext("Watched"), else: gettext("Listened")

      :archived ->
        gettext("Archived")
    end
  end

  def play_label(%{playback: %{status: :heard}}), do: gettext("Play again")
  def play_label(%{playback: %{position: position}}) when position > 0, do: gettext("Resume")
  def play_label(_entry), do: gettext("Play")

  def mark_done_label(entry),
    do: if(video?(entry), do: gettext("Mark as watched"), else: gettext("Mark as listened"))

  def mark_new_label(entry),
    do: if(video?(entry), do: gettext("Mark as unwatched"), else: gettext("Mark as unlistened"))

  @doc "What a failed refresh means for the reader, from the reason `Sikio.Feeds` stored."
  def refresh_problem(reason) when reason in ["invalid_feed", "unsupported_encoding"],
    do: gettext("The address no longer serves a feed Sikio can read.")

  def refresh_problem("gone"), do: gettext("The address no longer exists on its server.")
  def refresh_problem("too_large"), do: gettext("The feed is larger than Sikio reads.")
  def refresh_problem("too_many_redirects"), do: gettext("The address redirects too often.")

  def refresh_problem("unsafe_url"),
    do: gettext("The address leads somewhere Sikio does not fetch from.")

  def refresh_problem(_reason),
    do: gettext("The server could not be reached. Sikio will try again.")

  @doc "The picture that stands for an item or a source that brings none of its own."
  def kind_mark(%{feed: feed}), do: kind_mark(feed)
  def kind_mark(%{kind: kind}) when kind in [:youtube, :peertube], do: ~p"/images/kind-video.svg"
  def kind_mark(_source), do: ~p"/images/kind-audio.svg"

  @doc "The first letter of a name, which stands for it where no picture is shown."
  def initial(name), do: name |> to_string() |> String.trim() |> String.first() |> String.upcase()

  @doc "Where an item comes from, as a list row names it. Platforms keep their own names."
  def medium_label(%{feed: %{kind: :youtube}}), do: "YouTube"
  def medium_label(%{feed: %{kind: :peertube}}), do: "PeerTube"
  def medium_label(_entry), do: gettext("Podcast")

  @doc """
  Where an item can be opened at its source, and what the action is called: `{href, label}`.

  The page the feed named comes first. A YouTube video without one is still found by its id;
  any other item without one offers nothing rather than a guessed address.
  """
  def original(%{page_url: url} = entry) when is_binary(url), do: {url, original_label(entry)}

  def original(%{feed: %{kind: :youtube}, video_id: id} = entry) when is_binary(id),
    do: {"https://www.youtube.com/watch?v=#{id}", original_label(entry)}

  def original(_entry), do: nil

  defp original_label(%{feed: %{kind: :youtube}}), do: gettext("Open on YouTube")
  defp original_label(%{feed: %{kind: :peertube}}), do: gettext("Open on PeerTube")
  defp original_label(_entry), do: gettext("Open episode page")

  def timestamp(seconds) do
    seconds = trunc(seconds || 0)
    minutes = div(seconds, 60)
    "#{minutes}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  @doc "A runtime, stated or measured, as a list shows it: hours only when there are any, `nil` when unknown."
  def runtime(nil), do: nil
  def runtime(seconds) when is_float(seconds), do: seconds |> trunc() |> runtime()
  def runtime(seconds) when seconds < 3600, do: timestamp(seconds)

  def runtime(seconds),
    do: "#{div(seconds, 3600)}:" <> String.pad_leading(timestamp(rem(seconds, 3600)), 5, "0")

  @doc """
  The library's views: the filter value, the count's key and the name.

  The inbox comes first, the library's front, then the queue and the history. All items come
  last, the archived among them.
  """
  def views do
    [
      {"inbox", :inbox, gettext("Inbox")},
      {"queue", :queue, gettext("Queue")},
      {"heard", :heard, gettext("History")},
      {"", :all, gettext("All items")}
    ]
  end

  @doc "The lists within a source or a tag: what is new there, what was heard, and everything."
  def segments do
    [
      {"inbox", :inbox, gettext("New")},
      {"heard", :heard, gettext("Heard")},
      {"", :all, gettext("All items")}
    ]
  end

  @doc "A view's icon, wherever the view is named."
  attr :view, :atom, required: true
  attr :class, :any, default: "size-4"

  def view_icon(assigns) do
    ~H"""
    <Lucideicons.inbox :if={@view == :inbox} aria-hidden="true" class={@class} />
    <Lucideicons.list_ordered :if={@view == :queue} aria-hidden="true" class={@class} />
    <Lucideicons.history :if={@view == :heard} aria-hidden="true" class={@class} />
    <Lucideicons.library :if={@view == :all} aria-hidden="true" class={@class} />
    """
  end

  @doc "A day as a list and a heading show it, with the month in the reader's language."
  def date(datetime) do
    month = Enum.at(months(), datetime.month - 1)
    gettext("%{day} %{month} %{year}", day: datetime.day, month: month, year: datetime.year)
  end

  @doc "A date as a list shows it: the year only when it is not this one."
  def short_date(datetime, today \\ Date.utc_today()) do
    if datetime.year == today.year do
      month = Enum.at(months(), datetime.month - 1)
      gettext("%{day} %{month}", day: datetime.day, month: month)
    else
      date(datetime)
    end
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
