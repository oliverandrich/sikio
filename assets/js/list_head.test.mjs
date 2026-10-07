// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {ListHead} from "./list_head.mjs"

// The hook sets `--list-head` on the pane on mount and again on each head resize.
test("the list pane learns the height of its head", () => {
  const previous = globalThis.ResizeObserver
  let changed
  globalThis.ResizeObserver = class {
    constructor(callback) { changed = callback }
    observe() {}
    disconnect() { changed = null }
  }
  const properties = {}
  const pane = {style: {setProperty: (name, value) => { properties[name] = value }}}
  let height = 96.4
  const hook = {...ListHead, el: {parentElement: pane, getBoundingClientRect: () => ({height})}}
  try {
    hook.mounted()
    assert.equal(properties["--list-head"], "96px", "rounded down, so no gap shows between head and heading")
    height = 140
    changed()
    assert.equal(properties["--list-head"], "140px")
    hook.destroyed()
    assert.equal(changed, null)
  } finally {
    globalThis.ResizeObserver = previous
  }
})
