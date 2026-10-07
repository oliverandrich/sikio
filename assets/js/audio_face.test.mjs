// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {bindFace, clock, left, nextSpeed, renderMarks, skipped} from "./audio_face.mjs"

test("a clock shows hours only when there are any", () => {
  assert.equal(clock(0), "0:00")
  assert.equal(clock(61.9), "1:01")
  assert.equal(clock(1421), "23:41")
  assert.equal(clock(3723), "1:02:03")
  assert.equal(clock(NaN), "0:00")
})

// The remaining time is a countdown with a minus sign (U+2212), not a hyphen.
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

// The speed button cycles through the listed speeds, starting after the current rate.
test("the speed button steps through the speeds and wraps", () => {
  assert.equal(nextSpeed(1), 1.25)
  assert.equal(nextSpeed(2), 0.75)
  assert.equal(nextSpeed(0.75), 1)
  assert.equal(nextSpeed(1.1), 1.25, "an odd rate moves on to the next listed one")
})

function fixture({duration = 100, currentTime = 10, readyState = 1, seekValue = "0", chapters = []} = {}) {
  const audio = Object.assign(new EventTarget(), {duration, currentTime, readyState, paused: true, playbackRate: 1,
    play() { this.paused = false; this.dispatchEvent(new Event("play")); return Promise.resolve() },
    pause() { this.paused = true; this.dispatchEvent(new Event("pause")) }})
  const element = (attrs = {}) => Object.assign(new EventTarget(), {
    dataset: {}, textContent: "", style: {setProperty(name, value) { this[name] = value }},
    attributes: {}, setAttribute(name, value) { this.attributes[name] = value }, ...attrs})
  const parts = {
    play: element(), seek: element({value: seekValue, max: "3723", clientWidth: 416}), elapsed: element(), left: element(),
    back: element({dataset: {audioSkip: "-15"}}), forward: element({dataset: {audioSkip: "30"}}),
    speed: element(), chapter: element()
  }
  const marks = chapters.map(([at, title]) => element({dataset: {at: String(at), title}, hidden: true}))
  const face = Object.assign(element(), {
    querySelector: selector => ({
      "[data-audio-play]": parts.play, "[data-audio-seek]": parts.seek,
      "[data-audio-elapsed]": parts.elapsed, "[data-audio-left]": parts.left,
      "[data-audio-speed]": parts.speed, "[data-audio-chapter]": parts.chapter
    })[selector],
    querySelectorAll: selector => ({
      "[data-audio-skip]": [parts.back, parts.forward], "[data-audio-mark]": marks
    })[selector] ?? []
  })
  const strings = {play: "Play", pause: "Pause", positionOf: "{position} of {duration}", locale: "de"}
  const cleanup = bindFace(audio, face, strings)
  return {audio, face, parts, marks, cleanup}
}

// Before metadata loads, the audio reports position zero.
// The face keeps the server-rendered saved position instead of jumping to the start.
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

// Dragging updates the time display. Only release seeks, so the audio does not buffer each value.
// During a drag, `timeupdate` does not move the thumb.
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

// Dragging away and back to the same second fires no `change`.
// `pointerup` still ends the drag, or the bar would stop following the audio.
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

const chapters = [[0, "Intro"], [900, "Interview"], [1800, "Listener mail"], [5000, "Outtakes"]]

// The chapter line and the seek bar's `aria-valuetext` name the chapter under the thumb.
test("the face names the chapter that is playing", () => {
  const f = fixture({duration: 3600, currentTime: 1000, chapters})
  assert.equal(f.parts.chapter.textContent, "Interview")
  assert.equal(f.parts.seek.attributes["aria-valuetext"], "16:40 of 1:00:00, Interview")

  f.parts.seek.value = "2000"
  f.parts.seek.dispatchEvent(new Event("input"))
  assert.equal(f.parts.chapter.textContent, "Listener mail", "dragging names where it would land")
  f.cleanup()
})

// The server placed marks by the feed's stated length. The audio's own duration replaces it.
// A chapter at the start or past the end gets no visible mark.
test("the marks move to the length the audio states", () => {
  const f = fixture({duration: 3600, chapters})
  const [start, interview, mail, outtakes] = f.marks
  assert.equal(interview.style["--at"], "0.25")
  assert.equal(mail.style["--at"], "0.5")
  assert.equal(interview.hidden, false)
  assert.equal(start.hidden, true)
  assert.equal(outtakes.hidden, true)
  f.cleanup()
})

// Hovering names the chapter under the pointer. Leaving names the playing chapter.
// The thumb centre spans from 6px to 6px before the end, and positions map to that range.
test("hovering the bar names the chapter under the pointer", () => {
  const f = fixture({duration: 3600, currentTime: 100, chapters})
  f.parts.seek.max = "3600"
  const over = x => f.parts.seek.dispatchEvent(Object.assign(new Event("pointermove"), {offsetX: x}))
  over(6 + 404 * 0.6)
  assert.equal(f.parts.chapter.textContent, "Listener mail")
  over(0)
  assert.equal(f.parts.chapter.textContent, "Intro")
  f.parts.seek.dispatchEvent(new Event("pointerleave"))
  assert.equal(f.parts.chapter.textContent, "Intro")
  over(6 + 404 * 0.3)
  f.parts.seek.dispatchEvent(new Event("pointerleave"))
  assert.equal(f.parts.chapter.textContent, "Intro", "leaving names the chapter that plays")
  f.cleanup()
})

test("a mark the thumb has passed says so, and one ahead does not", () => {
  const f = fixture({duration: 3600, currentTime: 1000, chapters})
  assert.equal(f.marks[1].dataset.played, "")
  assert.equal(f.marks[2].dataset.played, undefined)
  f.audio.currentTime = 2000
  f.audio.dispatchEvent(new Event("timeupdate"))
  assert.equal(f.marks[2].dataset.played, "")
  f.audio.currentTime = 100
  f.audio.dispatchEvent(new Event("timeupdate"))
  assert.equal(f.marks[1].dataset.played, undefined)
  f.cleanup()
})

// The dock's face keeps its rendered markup, so script draws marks for chapters loaded later.
test("marks are drawn anew for the chapters the page learned", () => {
  const made = []
  const doc = {createElement: tag => {
    const el = {tag, dataset: {}, attributes: {}, style: {setProperty(name, value) { this[name] = value }},
      setAttribute(name, value) { this.attributes[name] = value }, remove() { this.removed = true }}
    made.push(el)
    return el
  }}
  const old = {dataset: {at: "5"}, remove() { this.removed = true }}
  const bar = {appended: [], append(...els) { this.appended.push(...els) }}
  const face = {querySelector: s => s === "[data-audio-bar]" ? bar : null,
    querySelectorAll: s => s === "[data-audio-mark]" ? [old] : []}

  renderMarks(face, [{at: 0, title: "Intro"}, {at: 90, title: "Akkus"}], 360, doc)
  assert.equal(old.removed, true)
  assert.deepEqual(bar.appended.map(el => [el.dataset.at, el.dataset.title, el.hidden]),
    [["0", "Intro", true], ["90", "Akkus", false]])
  assert.equal(bar.appended[1].style["--at"], "0.25")
  assert.equal(bar.appended[1].attributes["aria-hidden"], "true")
})

// The audio fires `timeupdate` several times a second during playback.
// That must not replace the hovered chapter's name.
test("playing does not overwrite the chapter under the pointer", () => {
  const f = fixture({duration: 3600, currentTime: 100, chapters})
  f.parts.seek.max = "3600"
  f.parts.seek.dispatchEvent(Object.assign(new Event("pointermove"), {offsetX: 6 + 404 * 0.6}))
  f.audio.currentTime = 101
  f.audio.dispatchEvent(new Event("timeupdate"))
  assert.equal(f.parts.chapter.textContent, "Listener mail")
  f.parts.seek.dispatchEvent(new Event("pointerleave"))
  f.audio.currentTime = 102
  f.audio.dispatchEvent(new Event("timeupdate"))
  assert.equal(f.parts.chapter.textContent, "Intro")
  f.cleanup()
})
