// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {placement} from "./dock_place.mjs"

test("on a narrow screen the panel floats above the bottom bar", () => {
  assert.equal(placement({wide: false, shown: "7", playing: "7"}), "floating")
})

test("the player sits at the top of the detail when that shows what plays", () => {
  assert.equal(placement({wide: true, shown: "7", playing: "7"}), "pinned")
})

// Playback is global and selection is not. When they disagree the notes get the room.
test("anything else folds it into the sidebar's now playing bar", () => {
  assert.equal(placement({wide: true, shown: "8", playing: "7"}), "compact")
  assert.equal(placement({wide: true, shown: null, playing: "7"}), "compact")
})
