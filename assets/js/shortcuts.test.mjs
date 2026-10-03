// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {opensShortcuts} from "./shortcuts.mjs"

const press = (key, extra = {}) => ({key, target: {tagName: "BODY"}, ...extra})

test("a question mark outside a field opens the overview of keys", () => {
  assert.equal(opensShortcuts(press("?", {shiftKey: true})), true)
  assert.equal(opensShortcuts(press("?", {target: {tagName: "INPUT"}})), false)
  assert.equal(opensShortcuts(press("?", {metaKey: true})), false)
  assert.equal(opensShortcuts(press("/")), false)
})
