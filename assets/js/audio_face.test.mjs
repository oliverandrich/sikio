// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {bindFace, clock, left, nextSpeed, skipped} from "./audio_face.mjs"

test("a clock shows hours only when there are any", () => {
  assert.equal(clock(0), "0:00")
  assert.equal(clock(61.9), "1:01")
  assert.equal(clock(1421), "23:41")
  assert.equal(clock(3723), "1:02:03")
  assert.equal(clock(NaN), "0:00")
})

// What is left reads as a countdown, with a real minus sign rather than a hyphen.
test("the time left counts down to the end", () => {
  assert.equal(left(1421, 4443), "−50:22")
  assert.equal(left(10, NaN), "")
  assert.equal(left(50, 40), "−0:00")
})

test("a skip stays between the start and the end", () => {
  assert.equal(skipped(10, -15, 100), 0)
  assert.equal(skipped(80, 30, 100), 100)
  assert.equal(skipped(40, 30, 100), 70)
  assert.equal(skipped(40, 30, NaN), 70, "an unknown length does not hold a skip back")
})

// One button steps through the speeds and comes round again, starting from the one in use.
test("the speed button steps through the speeds and wraps", () => {
  assert.equal(nextSpeed(1), 1.25)
  assert.equal(nextSpeed(2), 0.75)
  assert.equal(nextSpeed(0.75), 1)
  assert.equal(nextSpeed(1.1), 1.25, "an odd rate moves on to the next listed one")
})

function fixture({duration = 100, currentTime = 10, readyState = 1, seekValue = "0"} = {}) {
  const audio = Object.assign(new EventTarget(), {duration, currentTime, readyState, paused: true, playbackRate: 1,
    play() { this.paused = false; this.dispatchEvent(new Event("play")); return Promise.resolve() },
    pause() { this.paused = true; this.dispatchEvent(new Event("pause")) }})
  const element = (attrs = {}) => Object.assign(new EventTarget(), {
    dataset: {}, textContent: "", style: {setProperty(name, value) { this[name] = value }},
    attributes: {}, setAttribute(name, value) { this.attributes[name] = value }, ...attrs})
  const parts = {
    play: element(), seek: element({value: seekValue, max: "3723"}), elapsed: element(), left: element(),
    back: element({dataset: {audioSkip: "-15"}}), forward: element({dataset: {audioSkip: "30"}}),
    speed: element()
  }
  const face = Object.assign(element(), {
    querySelector: selector => ({
      "[data-audio-play]": parts.play, "[data-audio-seek]": parts.seek,
      "[data-audio-elapsed]": parts.elapsed, "[data-audio-left]": parts.left,
      "[data-audio-speed]": parts.speed
    })[selector],
    querySelectorAll: selector => selector === "[data-audio-skip]" ? [parts.back, parts.forward] : []
  })
  const strings = {play: "Play", pause: "Pause", positionOf: "{position} of {duration}", locale: "de"}
  const cleanup = bindFace(audio, face, strings)
  return {audio, face, parts, cleanup}
}

// Until the audio knows its length it answers zero for its place. The server already showed
// the saved place, and that is kept rather than flashing back to the start.
test("the face keeps the saved place until the audio can say where it is", () => {
  const f = fixture({duration: NaN, currentTime: 0, readyState: 0, seekValue: "1421"})
  assert.equal(f.parts.seek.value, "1421")
  f.audio.readyState = 1
  f.audio.duration = 3723
  f.audio.currentTime = 1421
  f.audio.dispatchEvent(new Event("loadedmetadata"))
  assert.equal(f.parts.elapsed.textContent, "23:41")
  f.cleanup()
})

test("the face plays and pauses and says which it will do", () => {
  const f = fixture()
  f.parts.play.dispatchEvent(new Event("click"))
  assert.equal(f.audio.paused, false)
  assert.equal(f.parts.play.attributes["aria-label"], "Pause")
  assert.equal(f.face.dataset.playing, "")
  f.parts.play.dispatchEvent(new Event("click"))
  assert.equal(f.audio.paused, true)
  assert.equal(f.parts.play.attributes["aria-label"], "Play")
  assert.equal(f.face.dataset.playing, undefined)
  f.cleanup()
})

// Dragging shows where it would land; only letting go moves the audio, so it does not buffer
// every place in between. Meanwhile the playing audio does not pull the thumb back.
test("the bar follows the audio, except while it is dragged", () => {
  const f = fixture()
  f.audio.currentTime = 30
  f.audio.dispatchEvent(new Event("timeupdate"))
  assert.equal(f.parts.seek.value, "30")
  assert.equal(f.parts.seek.max, "100")
  assert.equal(f.parts.elapsed.textContent, "0:30")
  assert.equal(f.parts.left.textContent, "−1:10")
  assert.equal(f.parts.seek.attributes["aria-valuetext"], "0:30 of 1:40")

  f.parts.seek.value = "80"
  f.parts.seek.dispatchEvent(new Event("input"))
  assert.equal(f.parts.elapsed.textContent, "1:20")
  assert.equal(f.audio.currentTime, 30, "dragging alone does not seek")
  f.audio.currentTime = 31
  f.audio.dispatchEvent(new Event("timeupdate"))
  assert.equal(f.parts.seek.value, "80", "the audio does not pull the thumb away")

  f.parts.seek.dispatchEvent(new Event("change"))
  assert.equal(f.audio.currentTime, 80)
  f.audio.currentTime = 81
  f.audio.dispatchEvent(new Event("timeupdate"))
  assert.equal(f.parts.seek.value, "81")
  f.cleanup()
})

// Dragging away and back to the same second fires no change. Letting go still ends the drag, or
// the bar would stop following the audio for good.
test("letting go ends a drag that changed nothing", () => {
  const f = fixture()
  f.parts.seek.value = "30"
  f.parts.seek.dispatchEvent(new Event("input"))
  f.parts.seek.dispatchEvent(new Event("pointerup"))
  f.audio.currentTime = 50
  f.audio.dispatchEvent(new Event("timeupdate"))
  assert.equal(f.parts.seek.value, "50")
  f.cleanup()
})

test("the skips and the speed act on the audio", () => {
  const f = fixture({currentTime: 40})
  f.parts.back.dispatchEvent(new Event("click"))
  assert.equal(f.audio.currentTime, 25)
  f.parts.forward.dispatchEvent(new Event("click"))
  assert.equal(f.audio.currentTime, 55)
  f.parts.speed.dispatchEvent(new Event("click"))
  assert.equal(f.audio.playbackRate, 1.25)
  assert.equal(f.parts.speed.textContent, "1,25×")
  f.cleanup()
})

test("cleaning up leaves the audio alone", () => {
  const f = fixture()
  f.cleanup()
  f.parts.play.dispatchEvent(new Event("click"))
  assert.equal(f.audio.paused, true)
})
