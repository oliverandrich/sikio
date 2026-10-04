// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {dropIndex, keyIndex, shifts} from "./queue_sort.mjs"

// The others' middles, top to bottom. The dragged row lands after every one its pointer passed.
test("a row dropped lands after the rows whose middle it passed", () => {
  const middles = [100, 200, 300]
  assert.equal(dropIndex(middles, 50), 0)
  assert.equal(dropIndex(middles, 150), 1)
  assert.equal(dropIndex(middles, 250), 2)
  assert.equal(dropIndex(middles, 900), 3)
})

// From the keyboard a row moves one place, and not past either end.
test("the arrow keys move a row one place within the list", () => {
  assert.equal(keyIndex("ArrowUp", 2, 4), 1)
  assert.equal(keyIndex("ArrowDown", 2, 4), 3)
  assert.equal(keyIndex("ArrowUp", 0, 4), null)
  assert.equal(keyIndex("ArrowDown", 3, 4), null)
  assert.equal(keyIndex("Enter", 1, 4), null)
})

// While a row is held the others make room where it would land: dragged down, the rows it
// passes move up a place; dragged up, they move down. Given per other row, top to bottom.
test("the other rows make room where the held row would land", () => {
  // Four rows, the second held: three others.
  assert.deepEqual(shifts(1, 1, 3), [0, 0, 0], "where it was, nothing moves")
  assert.deepEqual(shifts(1, 3, 3), [0, -1, -1], "to the end, the two below move up")
  assert.deepEqual(shifts(1, 0, 3), [1, 0, 0], "to the top, the one above moves down")
  assert.deepEqual(shifts(3, 0, 3), [1, 1, 1], "the last to the top, all move down")
})
