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

// Writes a place into a face: the times, what a screen reader says, and how far the bar is filled.
// The audio reports its time several times a second while the clock moves once; text is only
// written when it changes.
export function paint(face, position, duration, positionOf) {
  const write = (element, text) => { if (element.textContent !== text) element.textContent = text }
  const seek = part(face, "seek")
  write(part(face, "elapsed"), clock(position))
  write(part(face, "left"), left(position, duration))
  seek.setAttribute("aria-valuetext",
    positionOf.replace("{position}", clock(position)).replace("{duration}", clock(duration)))
  const share = duration > 0 ? Math.min(position / duration, 1) * 100 : 0
  seek.style.setProperty("--progress", `${share}%`)
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

  listen(speed, "click", () => {
    audio.playbackRate = nextSpeed(audio.playbackRate)
    speed.textContent = `${rate.format(audio.playbackRate)}×`
  })

  state()
  // Before its metadata the audio answers zero for its place. The server showed the saved one.
  if (audio.readyState >= 1) follow()
  return cleanup
}
