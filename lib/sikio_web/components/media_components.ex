defmodule SikioWeb.MediaComponents do
  @moduledoc """
  Shared playback labels and time formatting.

  Watched or listened depends on what the thing is, so the wording is decided here rather than in
  three templates that would drift apart.
  """
  use Gettext, backend: SikioWeb.Gettext

  def status(%{playback: nil}), do: :new
  def status(%{playback: state}), do: state.status

  def status_label(entry) do
    case status(entry) do
      :new ->
        gettext("New")

      :in_progress ->
        gettext("In progress")

      :completed ->
        if entry.feed.kind == :youtube, do: gettext("Watched"), else: gettext("Listened")
    end
  end

  def play_label(%{playback: %{status: :completed}}), do: gettext("Play again")
  def play_label(%{playback: %{position: position}}) when position > 0, do: gettext("Resume")
  def play_label(_entry), do: gettext("Play")

  def mark_done_label(%{feed: %{kind: :youtube}}), do: gettext("Mark as watched")
  def mark_done_label(_entry), do: gettext("Mark as listened")

  def mark_new_label(%{feed: %{kind: :youtube}}), do: gettext("Mark as unwatched")
  def mark_new_label(_entry), do: gettext("Mark as unlistened")

  def kind_label(%{feed: %{kind: :youtube}}), do: gettext("YouTube video")
  def kind_label(_entry), do: gettext("Podcast episode")

  def timestamp(seconds) do
    seconds = trunc(seconds || 0)
    minutes = div(seconds, 60)
    "#{minutes}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end
end
