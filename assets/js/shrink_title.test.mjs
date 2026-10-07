// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {ShrinkTitle} from "./shrink_title.mjs"

// The bar shows the page title while the large heading is under the bar, and hides it after.
// On a page without a large heading the bar drops `data-shrunk`.
test("the bar shows the title while the large heading is out of view", () => {
  const previous = {document: globalThis.document, IntersectionObserver: globalThis.IntersectionObserver}
  let seen, options
  const observed = []
  globalThis.IntersectionObserver = class {
    constructor(callback, opts) { seen = callback; options = opts }
    observe(el) { observed.push(el) }
    disconnect() { seen = null }
  }
  let heading = {id: "heading"}
  globalThis.document = {querySelector: selector => selector === "[data-large-title]" ? heading : null}
  const attributes = new Set()
  const el = {offsetHeight: 56, toggleAttribute: (name, on) => on ? attributes.add(name) : attributes.delete(name)}
  const hook = {...ShrinkTitle, el}
  try {
    hook.mounted()
    assert.deepEqual(observed, [heading])
    assert.equal(options.rootMargin, "-56px 0px 0px 0px", "the heading counts as gone once under the bar")
    seen([{isIntersecting: false}])
    assert.ok(attributes.has("data-shrunk"))
    seen([{isIntersecting: true}])
    assert.ok(!attributes.has("data-shrunk"))

    // An update with the same heading does not observe it again.
    hook.updated()
    assert.equal(observed.length, 1)

    // An update without a large heading removes `data-shrunk`.
    seen([{isIntersecting: false}])
    heading = null
    hook.updated()
    assert.ok(!attributes.has("data-shrunk"))
    hook.destroyed()
  } finally {
    globalThis.document = previous.document
    globalThis.IntersectionObserver = previous.IntersectionObserver
  }
})
