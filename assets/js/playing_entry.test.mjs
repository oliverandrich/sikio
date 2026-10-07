// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {PlayingEntry} from "./playing_entry.mjs"

function mount(dock) {
  const previous = globalThis.document
  globalThis.document = {querySelector: selector => selector === "#player-control" ? dock : null}
  const input = {value: ""}
  const el = {hidden: true, querySelector: selector => selector === "input[name=playing_id]" ? input : null}
  try {
    PlayingEntry.mounted.call({el})
  } finally {
    globalThis.document = previous
  }
  return {el, input}
}

// The player-item option is visible only while the player has an entry, and carries its id.
test("the player's item is offered only while there is one", () => {
  const playing = mount({dataset: {entryId: "42"}})
  assert.equal(playing.el.hidden, false)
  assert.equal(playing.input.value, "42")

  const idle = mount({dataset: {entryId: ""}})
  assert.equal(idle.el.hidden, true)
  assert.equal(idle.input.value, "")

  assert.equal(mount(null).el.hidden, true)
})
