# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MediaComponents do
  @moduledoc """
  Shared playback labels, time formatting and the view icons.

  Labels say "watched" for video and "listened" for audio.
  The choice is made here once instead of in each template.
  """
  use Phoenix.Component
  use Gettext, backend: SikioWeb.Gettext
  use SikioWeb, :verified_routes

  @doc """
  Returns the subscription's custom name, or else the feed title.

  For an entry, returns the `source_name` selected by the library query, else the feed title.
  """
  def source_name(%Sikio.Library.Subscription{name: name, feed: feed}), do: name || feed.title
  def source_name(%{source_name: name}) when is_binary(name), do: name
  def source_name(%{feed: feed}), do: feed.title

  @doc "Returns true for YouTube and PeerTube entries."
  def video?(%{feed: %{kind: kind}}), do: kind in [:youtube, :peertube]

  @doc "Returns the translated label for a source's kind."
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

  @doc "Returns a user-facing message for a refresh error reason stored by `Sikio.Feeds`."
  def refresh_problem(reason) when reason in ["invalid_feed", "unsupported_encoding"],
    do: gettext("The address no longer serves a feed Sikio can read.")

  def refresh_problem("gone"), do: gettext("The address no longer exists on its server.")
  def refresh_problem("too_large"), do: gettext("The feed is larger than Sikio reads.")
  def refresh_problem("too_many_redirects"), do: gettext("The address redirects too often.")

  def refresh_problem("unsafe_url"),
    do: gettext("The address leads somewhere Sikio does not fetch from.")

  def refresh_problem(_reason),
    do: gettext("The server could not be reached. Sikio will try again.")

  @doc "Returns the placeholder image path for an entry or feed without artwork."
  def kind_mark(%{feed: feed}), do: kind_mark(feed)
  def kind_mark(%{kind: kind}) when kind in [:youtube, :peertube], do: ~p"/images/kind-video.svg"
  def kind_mark(_source), do: ~p"/images/kind-audio.svg"

  @doc "Returns the uppercased first letter of a name, shown where no image is available."
  def initial(name), do: name |> to_string() |> String.trim() |> String.first() |> String.upcase()

  @doc "Returns the medium label for a list row. Platform names are not translated."
  def medium_label(%{feed: %{kind: :youtube}}), do: "YouTube"
  def medium_label(%{feed: %{kind: :peertube}}), do: "PeerTube"
  def medium_label(_entry), do: gettext("Podcast")

  @doc """
  Returns `{href, label}` for opening an entry at its source, or nil.

  The entry's `page_url` takes precedence. A YouTube entry without one uses its video id.
  Other entries without `page_url` return nil instead of a guessed URL.
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

  @doc "Formats seconds as `m:ss`, or `h:mm:ss` from one hour. Returns nil for nil."
  def runtime(nil), do: nil
  def runtime(seconds) when is_float(seconds), do: seconds |> trunc() |> runtime()
  def runtime(seconds) when seconds < 3600, do: timestamp(seconds)

  def runtime(seconds),
    do: "#{div(seconds, 3600)}:" <> String.pad_leading(timestamp(rem(seconds, 3600)), 5, "0")

  @doc """
  Returns the library views as `{filter value, count key, label}`.

  The order is inbox, queue, history, then all items.
  All items includes archived entries.
  """
  def views do
    [
      {"inbox", :inbox, gettext("Inbox")},
      {"queue", :queue, gettext("Queue")},
      {"heard", :heard, gettext("History")},
      {"", :all, gettext("All items")}
    ]
  end

  @doc """
  Returns the segments within a source or tag: unfinished, finished and all items.

  `videos` holds `video?/1` for each source of the place and names the finished items.
  """
  def status_segments(videos) do
    finished =
      case Enum.uniq(videos) do
        [false] -> gettext("Listened")
        [true] -> gettext("Watched")
        _mixed_or_none -> gettext("Listened & watched")
      end

    [
      {"open", :open, gettext("Unfinished")},
      {"heard", :heard, finished},
      {"", :all, gettext("All items")}
    ]
  end

  @doc "Renders the icon for a library view."
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

  @doc "Formats a date as day, translated month abbreviation and year."
  def date(datetime) do
    month = Enum.at(months(), datetime.month - 1)
    gettext("%{day} %{month} %{year}", day: datetime.day, month: month, year: datetime.year)
  end

  @doc "Formats a date like `date/1`, omitting the year when it is the current year."
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
