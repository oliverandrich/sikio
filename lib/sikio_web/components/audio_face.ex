# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AudioFace do
  @moduledoc """
  Sikio's own controls for an episode, one markup in two places.

  The dock renders them over an audio element that keeps no controls of its own, and
  `assets/js/audio_face.mjs` drives that element. The detail card renders the same face as a cue
  before anything loads: pressing play, dragging or skipping starts the dock's player there, see
  `assets/js/audio_cue.mjs`. Looking alike, the one lies over the other without a jump.
  """
  use Phoenix.Component
  use Gettext, backend: SikioWeb.Gettext

  import SikioWeb.MediaComponents, only: [play_label: 1, runtime: 1]

  attr :length, :integer, default: nil, doc: "the episode's length in seconds, when known"
  attr :position, :any, required: true, doc: "the place in seconds"
  attr :cue, :map, default: nil, doc: "the entry, when this is the card's cue"
  attr :chapters, :list, default: [], doc: "the chapters as `%{at: seconds, title: text}`"
  attr :rest, :global

  def audio_face(assigns) do
    %{position: position, length: length} = assigns
    position = trunc(position || 0)

    assigns =
      assign(assigns,
        position: position,
        share: if(length && length > 0, do: min(position / length, 1), else: 0),
        playing: chapter_at(assigns.chapters, position)
      )

    ~H"""
    <div data-audio-face class="audio-face" {@rest}>
      <button
        type="button"
        id={@cue && "start-playback"}
        data-audio-play
        aria-label={if @cue, do: play_label(@cue), else: gettext("Play")}
        class="audio-play"
      >
        <Lucideicons.play aria-hidden="true" class="audio-icon-play size-5 fill-current" />
        <Lucideicons.pause aria-hidden="true" class="audio-icon-pause size-5 fill-current" />
      </button>
      <div class="audio-track">
        <div data-audio-bar class="audio-bar" style={"--share: #{@share}"}>
          <input
            type="range"
            data-audio-seek
            aria-label={gettext("Position")}
            min="0"
            max={@length || @position}
            data-length={@length}
            disabled={@cue != nil && is_nil(@length)}
            step="1"
            value={@position}
            class="audio-seek"
          />
          <%!-- Where each chapter begins, as decoration: the bar under it takes every press and
        drag. assets/js/audio_face.mjs moves the marks once the player knows the length. --%>
          <span
            :for={chapter <- @chapters}
            data-audio-mark
            data-at={chapter.at}
            data-title={chapter.title}
            data-played={chapter.at <= @position}
            aria-hidden="true"
            hidden={!marked?(chapter, @length)}
            style={@length && @length > 0 && "--at: #{chapter.at / @length}"}
            class="audio-mark"
          ></span>
        </div>
        <div class="audio-times">
          <span data-audio-elapsed>{runtime(@position) || "0:00"}</span>
          <span data-audio-chapter class="audio-chapter">{@playing}</span>
          <span data-audio-left>{@length && "−" <> runtime(max(@length - @position, 0))}</span>
        </div>
      </div>
      <button
        type="button"
        data-audio-skip="-15"
        aria-label={gettext("15 seconds back")}
        class="audio-skip audio-back"
      >
        <Lucideicons.rotate_ccw aria-hidden="true" class="size-5" />
        <span aria-hidden="true">15</span>
      </button>
      <button
        type="button"
        data-audio-skip="30"
        aria-label={gettext("30 seconds forward")}
        class="audio-skip audio-forward"
      >
        <Lucideicons.rotate_cw aria-hidden="true" class="size-5" />
        <span aria-hidden="true">30</span>
      </button>
      <%!-- Before anything plays there is no speed to set; the dock's face takes it over. --%>
      <button
        type="button"
        data-audio-speed
        aria-label={gettext("Playback speed")}
        disabled={@cue != nil}
        class="audio-speed"
      >
        1×
      </button>
    </div>
    """
  end

  # The bar begins at the start, so a chapter there needs no mark; one past the end has no place.
  defp marked?(%{at: at}, length), do: is_number(length) and at > 0 and at < length

  defp chapter_at(chapters, position) do
    chapters |> Enum.filter(&(&1.at <= position)) |> List.last() |> then(&(&1 && &1.title))
  end
end
