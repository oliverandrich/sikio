// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {placement, stuckFrom} from "./dock_place.mjs"

// A phone shows what plays in its detail, as a wide screen does. Elsewhere the panel floats.
test("on a narrow screen the panel sits in the detail that shows what plays", () => {
  assert.equal(placement({wide: false, shown: "7", playing: "7"}), "pinned")
  assert.equal(placement({wide: false, shown: "8", playing: "7"}), "floating")
  assert.equal(placement({wide: false, shown: null, playing: "7"}), "floating")
})

test("the player sits at the top of the detail when that shows what plays", () => {
  assert.equal(placement({wide: true, shown: "7", playing: "7"}), "pinned")
})

// Playback is global and selection is not. When they disagree the notes get the room.
test("anything else folds it into the sidebar's now playing bar", () => {
  assert.equal(placement({wide: true, shown: "8", playing: "7"}), "compact")
  assert.equal(placement({wide: true, shown: null, playing: "7"}), "compact")
})

// A slow page can collect several crossings before the observer reports them, oldest first. Only
// the last one says where the slot is now.
test("the slot is stuck as the last of the observer's entries says", () => {
  assert.equal(stuckFrom([{isIntersecting: true}]), true)
  assert.equal(stuckFrom([{isIntersecting: true}, {isIntersecting: false}]), false)
  assert.equal(stuckFrom([{isIntersecting: false}, {isIntersecting: true}]), true)
})
