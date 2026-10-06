// SPDX-License-Identifier: AGPL-3.0-or-later

// Sikio's own face for an audio element, which stays in the page without controls of its own.
// media_player.mjs keeps reading and saving the position through that element; this file only
// shows it and turns presses into calls on it. The markup is the dock's, rendered by the server,
// so every word here comes from it.

const SPEEDS = [0.75, 1, 1.25, 1.5, 1.75, 2]

// A time as the player shows it: hours only when there are any.
export function clock(seconds) {
  const total = Number.isFinite(seconds) && seconds > 0 ? Math.floor(seconds) : 0
  const [h, m, s] = [Math.floor(total / 3600), Math.floor(total / 60) % 60, total % 60]
  const pad = n => String(n).padStart(2, "0")
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`
}

// What is left, as a countdown with a real minus sign. Unknown when the length is.
export function left(position, duration) {
  if (!Number.isFinite(duration) || duration <= 0) return ""
  return "−" + clock(Math.max(duration - position, 0))
}

export function skipped(position, by, duration) {
  const target = Math.max(position + by, 0)
  return Number.isFinite(duration) && duration > 0 ? Math.min(target, duration) : target
}

// The next listed speed above the one in use, round to the slowest after the fastest.
export function nextSpeed(rate) {
  return SPEEDS.find(speed => speed > rate + 0.001) ?? SPEEDS[0]
}

// One of a face's controls, by the name its data-audio attribute gives it.
export const part = (face, name) => face.querySelector(`[data-audio-${name}]`)

// The length the feed named. The bar's own range is that only when one was named.
export const feedLength = face => Number(part(face, "seek").dataset.length) || NaN

// Listeners that can all be taken off again at once.
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

// The chapter marks a face carries, each with where its chapter begins and its title.
const marks = face => [...face.querySelectorAll("[data-audio-mark]")]

// The title of the chapter that a place lies in, or nothing before the first or without any.
export function chapterAt(face, position) {
  return marks(face).filter(mark => Number(mark.dataset.at) <= position).at(-1)?.dataset.title ?? ""
}

// Moves the marks to the length the player knows. The start needs none, and past the end has none.
export function placeMarks(face, duration, list = marks(face)) {
  if (!(duration > 0)) return
  for (const mark of list) {
    const at = Number(mark.dataset.at)
    mark.style.setProperty("--at", String(at / duration))
    mark.hidden = !(at > 0 && at < duration)
  }
}

// Draws the marks anew, for a face the page does not render again, such as the dock's.
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

// The bar names the chapter under the pointer while it hovers, and the one that plays after.
// The thumb's centre runs from 6px in to 6px short of the end, and the place with it.
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

// Writes a place into a face: the times, the chapter, what a screen reader says, and how far the
// bar is filled. The audio reports its time several times a second while the clock moves once;
// text is only written when it changes.
export function paint(face, position, duration, positionOf) {
  const write = (element, text) => { if (element && element.textContent !== text) element.textContent = text }
  const seek = part(face, "seek")
  const chapter = chapterAt(face, position)
  write(part(face, "elapsed"), clock(position))
  // The pointer's chapter stands while it hovers the bar; see namesHovered.
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

  // The length the audio states once it knows it, before that the one the feed named.
  const length = () =>
    Number.isFinite(audio.duration) && audio.duration > 0 ? audio.duration : feedLength(face)

  const show = position => paint(face, position, length(), strings.positionOf)

  const follow = () => {
    if (dragging) return
    if (Number.isFinite(audio.duration) && audio.duration > 0) seek.max = String(Math.floor(audio.duration))
    seek.value = String(Math.floor(audio.currentTime))
    show(audio.currentTime)
  }

  // The event says what happened; the element's own flag may lag behind it.
  const state = (playing = !audio.paused) => {
    play.setAttribute("aria-label", playing ? strings.pause : strings.play)
    if (playing) face.dataset.playing = ""
    else delete face.dataset.playing
  }

  listen(play, "click", () => { if (audio.paused) audio.play().catch(() => {}); else audio.pause() })
  listen(audio, "play", () => state(true))
  for (const event of ["pause", "ended"]) listen(audio, event, () => state(false))
  for (const event of ["timeupdate", "loadedmetadata", "seeked", "durationchange"]) listen(audio, event, follow)

  // Dragging shows where the thumb would land. Letting go, or a key, moves the audio.
  listen(seek, "input", () => { dragging = true; show(Number(seek.value)) })
  // Dragging back to where it started fires no change, so letting go ends the drag as well.
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
  // The marks move only when the length does, not with every tick of the clock.
  for (const event of ["loadedmetadata", "durationchange"]) listen(audio, event, () => placeMarks(face, length()))

  listen(speed, "click", () => {
    audio.playbackRate = nextSpeed(audio.playbackRate)
    speed.textContent = `${rate.format(audio.playbackRate)}×`
  })

  state()
  // Before its metadata the audio answers zero for its place. The server showed the saved one.
  if (audio.readyState >= 1) {
    placeMarks(face, length())
    follow()
  }
  return cleanup
}
