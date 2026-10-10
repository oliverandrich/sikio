# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AudioFace do
  @moduledoc """
  Audio player controls, rendered in two places with the same markup.

  The dock renders them for an `audio` element without native controls.
  `assets/js/audio_face.mjs` binds them to that element.
  The detail card renders them as a cue before any audio loads.
  Play, releasing the seek bar or skipping starts the dock's player at that position.
  See `assets/js/audio_cue.mjs`.
  Identical markup lets the dock's player replace the cue without a layout shift.
  """
  use Phoenix.Component
  use Gettext, backend: SikioWeb.Gettext

  import SikioWeb.MediaComponents, only: [play_label: 1, runtime: 1]

  attr :length, :integer, default: nil, doc: "the episode's length in seconds, when known"
  attr :position, :any, required: true, doc: "the place in seconds"
  attr :cue, :map, default: nil, doc: "the entry, when this is the card's cue"
  attr :chapters, :list, default: [], doc: "the chapters as `%{at: seconds, title: text}`"
  attr :sound, :boolean, default: false, doc: "whether a video offers its audio-only file"
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
          <%!-- Chapter start marks. They have `pointer-events: none`; the range input gets the
        input. assets/js/audio_face.mjs repositions them once the media duration is known. --%>
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
      <%!-- Disabled on the cue, which has no media element. The dock's controls set speed. --%>
      <button
        type="button"
        data-audio-speed
        aria-label={gettext("Playback speed")}
        disabled={@cue != nil}
        class="audio-speed"
      >
        1×
      </button>
      <%!-- Switches a video to its audio-only file; see assets/js/media_player.mjs.
      Disabled on the cue, like the speed button. --%>
      <button
        :if={@sound}
        type="button"
        data-audio-only
        disabled={@cue != nil}
        aria-pressed="false"
        aria-label={gettext("Sound only")}
        title={gettext("Sound only")}
        class="audio-sound"
      >
        <Lucideicons.headphones aria-hidden="true" class="size-5" />
      </button>
    </div>
    """
  end

  # A chapter at 0 needs no mark. A chapter at or past the length has no position on the bar.
  defp marked?(%{at: at}, length), do: is_number(length) and at > 0 and at < length

  defp chapter_at(chapters, position) do
    chapters |> Enum.filter(&(&1.at <= position)) |> List.last() |> then(&(&1 && &1.title))
  end
end
