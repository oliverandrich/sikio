// SPDX-License-Identifier: AGPL-3.0-or-later

// Custom controls for an audio element without native controls.
// media_player.mjs reads and saves the position through the audio element.
// `bindFace` renders that state and maps control input to calls on the element.
// audio_cue.mjs reuses the helpers for the card's cue.
// The server renders the markup. Labels come from its data attributes.

const SPEEDS = [0.75, 1, 1.25, 1.5, 1.75, 2]

// Formats seconds as m:ss, or h:mm:ss from one hour.
export function clock(seconds) {
  const total = Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0
  const [h, m, s] = [Math.floor(total / 3600), Math.floor(total / 60) % 60, total % 60]
  const pad = n => String(n).padStart(2, "0")
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`
}

// Remaining time with a U+2212 minus sign. Empty when the duration is unknown.
export function left(position, duration) {
  if (!Number.isFinite(duration) || duration <= 0) return ""
  return "−" + clock(Math.max(duration - position, 0))
}

export function skipped(position, by, duration) {
  const target = Math.max(position + by, 0)
  return Number.isFinite(duration) && duration > 0 ? Math.min(target, duration) : target
}

// The next speed in SPEEDS above `rate`. After the fastest it wraps to the slowest.
export function nextSpeed(rate) {
  return SPEEDS.find(speed => speed > rate + 0.001) ?? SPEEDS[0]
}

export const part = (face, name) => face.querySelector(`[data-audio-${name}]`)

// The duration from the feed, read from `data-length`. NaN when the feed named none.
export const feedLength = face => Number(part(face, "seek").dataset.length) || NaN

// Collects event listeners so `cleanup` removes them all.
export function listener() {
  const cleanups = []
  return {
    listen(target, event, callback) {
      target.addEventListener(event, callback)
      cleanups.push(() => target.removeEventListener(event, callback))
    },
    cleanup: () => cleanups.forEach(cleanup => cleanup())
  }
}

const marks = face => [...face.querySelectorAll("[data-audio-mark]")]

// Title of the chapter containing `position`. Empty before the first chapter or without chapters.
export function chapterAt(face, position) {
  return marks(face).filter(mark => Number(mark.dataset.at) <= position).at(-1)?.dataset.title ?? ""
}

// Positions the marks for `duration` via `--at`. Marks at 0 or at or after the end are hidden.
export function placeMarks(face, duration, list = marks(face)) {
  if (!(duration > 0)) return
  for (const mark of list) {
    const at = Number(mark.dataset.at)
    mark.style.setProperty("--at", String(at / duration))
    mark.hidden = !(at > 0 && at < duration)
  }
}

// Replaces the marks in a face that LiveView does not patch, such as the dock's.
export function renderMarks(face, chapters, duration, doc = document) {
  for (const mark of marks(face)) mark.remove()
  const drawn = chapters.map(({at, title}) => {
    const mark = doc.createElement("span")
    mark.dataset.audioMark = ""
    mark.dataset.at = String(at)
    mark.dataset.title = title
    mark.setAttribute("aria-hidden", "true")
    mark.className = "audio-mark"
    mark.hidden = true
    return mark
  })
  part(face, "bar").append(...drawn)
  placeMarks(face, duration, drawn)
}

// While the pointer hovers the seek bar, the label shows the chapter under it.
// On `pointerleave` it shows the chapter at the current value again.
// The thumb centre ranges from 6px to width minus 6px. The pointer offset maps to that range.
export function namesHovered(face, listen) {
  const seek = part(face, "seek"), label = part(face, "chapter")
  if (!label) return
  listen(seek, "pointermove", event => {
    label.dataset.hovered = ""
    const share = (event.offsetX - 6) / Math.max(seek.clientWidth - 12, 1)
    label.textContent = chapterAt(face, Math.min(Math.max(share, 0), 1) * Number(seek.max))
  })
  listen(seek, "pointerleave", () => {
    delete label.dataset.hovered
    label.textContent = chapterAt(face, Number(seek.value))
  })
}

// Renders a position: times, chapter label, chapter marks, `aria-valuetext` and `--share`.
// `timeupdate` fires several times per second, but the displayed time changes once per second.
// Text is written only when it changes.
export function paint(face, position, duration, positionOf) {
  const write = (element, text) => { if (element && element.textContent !== text) element.textContent = text }
  const seek = part(face, "seek")
  const chapter = chapterAt(face, position)
  write(part(face, "elapsed"), clock(position))
  // While the pointer hovers the bar, the label keeps the hovered chapter; see namesHovered.
  const label = part(face, "chapter")
  if (!label || !("hovered" in label.dataset)) write(label, chapter)
  write(part(face, "left"), left(position, duration))
  for (const mark of marks(face)) {
    const played = Number(mark.dataset.at) <= position
    if (played !== ("played" in mark.dataset)) {
      if (played) mark.dataset.played = ""
      else delete mark.dataset.played
    }
  }
  const where = positionOf.replace("{position}", clock(position)).replace("{duration}", clock(duration))
  seek.setAttribute("aria-valuetext", chapter ? `${where}, ${chapter}` : where)
  const share = duration > 0 ? Math.min(position / duration, 1) : 0
  ;(part(face, "bar") ?? seek).style.setProperty("--share", String(share))
}

export function bindFace(audio, face, strings) {
  const play = part(face, "play"), seek = part(face, "seek"), speed = part(face, "speed")
  const rate = new Intl.NumberFormat(strings.locale, {maximumFractionDigits: 2})
  const {listen, cleanup} = listener()
  let dragging = false

  // The audio element's duration once known, otherwise the feed's duration.
  const length = () =>
    Number.isFinite(audio.duration) && audio.duration > 0 ? audio.duration : feedLength(face)

  const show = position => paint(face, position, length(), strings.positionOf)

  const follow = () => {
    if (dragging) return
    if (Number.isFinite(audio.duration) && audio.duration > 0) seek.max = String(Math.floor(audio.duration))
    seek.value = String(Math.floor(audio.currentTime))
    show(audio.currentTime)
  }

  // Event listeners pass the state explicitly. `audio.paused` can lag behind the event.
  const state = (playing = !audio.paused) => {
    play.setAttribute("aria-label", playing ? strings.pause : strings.play)
    if (playing) face.dataset.playing = ""
    else delete face.dataset.playing
  }

  listen(play, "click", () => { if (audio.paused) audio.play().catch(() => {}); else audio.pause() })
  listen(audio, "play", () => state(true))
  for (const event of ["pause", "ended"]) listen(audio, event, () => state(false))
  for (const event of ["timeupdate", "loadedmetadata", "seeked", "durationchange"]) listen(audio, event, follow)

  // `input` only updates the display. `change`, from release or a key, sets `currentTime`.
  listen(seek, "input", () => { dragging = true; show(Number(seek.value)) })
  // Dragging back to the start value fires no `change`, so these events also end the drag.
  for (const event of ["pointerup", "keyup", "blur"]) listen(seek, event, () => { dragging = false })
  listen(seek, "change", () => {
    dragging = false
    audio.currentTime = Number(seek.value)
    follow()
  })

  for (const button of face.querySelectorAll("[data-audio-skip]")) {
    listen(button, "click", () => {
      audio.currentTime = skipped(audio.currentTime, Number(button.dataset.audioSkip), length())
      follow()
    })
  }

  namesHovered(face, listen)
  // Marks are repositioned only when the duration changes, not on `timeupdate`.
  for (const event of ["loadedmetadata", "durationchange"]) listen(audio, event, () => placeMarks(face, length()))

  listen(speed, "click", () => {
    audio.playbackRate = nextSpeed(audio.playbackRate)
    speed.textContent = `${rate.format(audio.playbackRate)}×`
  })

  state()
  // Before metadata loads, `currentTime` is 0. The server-rendered saved position stays until then.
  if (audio.readyState >= 1) {
    placeMarks(face, length())
    follow()
  }
  return cleanup
}
