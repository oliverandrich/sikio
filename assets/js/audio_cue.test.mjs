// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {bindCue} from "./audio_cue.mjs"

function fixture({value = "42", max = "3723", length = max} = {}) {
  const element = (attrs = {}) => Object.assign(new EventTarget(), {
    dataset: {}, textContent: "", style: {setProperty(name, v) { this[name] = v }},
    attributes: {}, setAttribute(name, v) { this.attributes[name] = v }, ...attrs})
  const parts = {
    play: element(), seek: element({value, max, dataset: {length}, clientWidth: 416}), elapsed: element(), left: element(),
    back: element({dataset: {audioSkip: "-15"}}), forward: element({dataset: {audioSkip: "30"}}),
    mark: element({dataset: {at: "900", title: "Interview"}}), chapter: element()
  }
  const face = Object.assign(element(), {
    querySelector: selector => ({
      "[data-audio-play]": parts.play, "[data-audio-seek]": parts.seek,
      "[data-audio-elapsed]": parts.elapsed, "[data-audio-left]": parts.left,
      "[data-audio-chapter]": parts.chapter
    })[selector],
    querySelectorAll: selector => ({
      "[data-audio-skip]": [parts.back, parts.forward], "[data-audio-mark]": [parts.mark]
    })[selector] ?? []
  })
  const starts = []
  const cleanup = bindCue(face, {start: position => starts.push(position), positionOf: "{position} of {duration}"})
  return {parts, starts, cleanup}
}

// Play calls `start` with `null`, which resumes at the saved position.
test("play starts the episode where it was left", () => {
  const f = fixture()
  f.parts.play.dispatchEvent(new Event("click"))
  assert.deepEqual(f.starts, [null])
  f.cleanup()
})

test("dragging shows the place and letting go starts there", () => {
  const f = fixture()
  f.parts.seek.value = "600"
  f.parts.seek.dispatchEvent(new Event("input"))
  assert.equal(f.parts.elapsed.textContent, "10:00")
  assert.equal(f.parts.left.textContent, "−52:03")
  assert.deepEqual(f.starts, [], "dragging alone loads nothing")
  f.parts.seek.dispatchEvent(new Event("change"))
  assert.deepEqual(f.starts, [600])
  f.cleanup()
})

test("a skip starts at the place it skips to, within the episode", () => {
  const f = fixture({value: "10"})
  f.parts.back.dispatchEvent(new Event("click"))
  f.parts.forward.dispatchEvent(new Event("click"))
  assert.deepEqual(f.starts, [0, 40])
  f.cleanup()
})

// A feed without a length gives the seek bar no range. The cue keeps the position separately.
// So a forward skip is not capped at the saved position.
test("without a known length a skip still starts from the saved place", () => {
  const f = fixture({value: "600", max: "600", length: ""})
  f.parts.back.dispatchEvent(new Event("click"))
  f.parts.forward.dispatchEvent(new Event("click"))
  assert.deepEqual(f.starts, [585, 630])
  f.cleanup()
})

// The card's seek bar shows the chapter under the pointer before playback.
test("hovering the card's bar names the chapter under the pointer", () => {
  const f = fixture({value: "0", max: "3600"})
  f.parts.seek.dispatchEvent(Object.assign(new Event("pointermove"), {offsetX: 6 + 404 * 0.5}))
  assert.equal(f.parts.chapter.textContent, "Interview")
  f.parts.seek.dispatchEvent(new Event("pointerleave"))
  assert.equal(f.parts.chapter.textContent, "")
  f.cleanup()
})
