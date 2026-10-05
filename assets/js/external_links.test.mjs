// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {leavesApp, openAway} from "./external_links.mjs"

const origin = "https://sikio.example.org"

test("a link to another host leaves the app, one within it does not", () => {
  assert.equal(leavesApp("https://www.youtube.com/watch?v=x", origin), true)
  assert.equal(leavesApp("https://sikio.example.org/inbox", origin), false)
  assert.equal(leavesApp("/inbox", origin), false)
  assert.equal(leavesApp("#notes", origin), false)
})

test("only the web's addresses count, not mail or a script", () => {
  assert.equal(leavesApp("mailto:ada@example.org", origin), false)
  assert.equal(leavesApp("javascript:void(0)", origin), false)
})

// A link that names no target of its own is sent to a tab of its own when it leaves the app.
test("a click on a link away gives it a tab of its own", () => {
  const link = {href: "https://example.org/show", target: "", rel: ""}
  const event = {target: {closest: () => link}}

  openAway(event, origin)

  assert.equal(link.target, "_blank")
  assert.equal(link.rel, "noopener noreferrer")
})

test("a link that chose its target keeps it, and a link within the app is left alone", () => {
  const chosen = {href: "https://example.org/show", target: "_self", rel: ""}
  openAway({target: {closest: () => chosen}}, origin)
  assert.equal(chosen.target, "_self")

  const inside = {href: "https://sikio.example.org/queue", target: "", rel: ""}
  openAway({target: {closest: () => inside}}, origin)
  assert.equal(inside.target, "")

  openAway({target: {closest: () => null}}, origin)
})
