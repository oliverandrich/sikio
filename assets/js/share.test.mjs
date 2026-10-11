// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {share} from "./share.mjs"

const link = {title: "One & two", url: "https://example.org/episodes/1"}

// A clipboard that records what it was given.
function clipboard() {
  const written = []
  return {written, writeText: async text => { written.push(text) }}
}

test("the system's share sheet gets the title and the address", async () => {
  const shared = [], board = clipboard()
  let copied = 0
  await share(link, {navigator: {share: async data => { shared.push(data) }, clipboard: board},
    copied: () => { copied += 1 }, failed: () => assert.fail("nothing failed")})

  assert.deepEqual(shared, [link])
  assert.deepEqual(board.written, [])
  assert.equal(copied, 0)
})

// Closing the sheet without sharing is a choice, not a failure.
test("a closed share sheet copies nothing", async () => {
  const board = clipboard()
  let copied = 0
  const abort = Object.assign(new Error("closed"), {name: "AbortError"})
  await share(link, {navigator: {share: async () => { throw abort }, clipboard: board},
    copied: () => { copied += 1 }, failed: () => assert.fail("nothing failed")})

  assert.deepEqual(board.written, [])
  assert.equal(copied, 0)
})

// Some desktop browsers have no share sheet. A refused one, as without a user gesture, falls back too.
test("without a share sheet the address goes to the clipboard", async () => {
  for (const sheet of [undefined, async () => { throw Object.assign(new Error("no"), {name: "NotAllowedError"}) }]) {
    const board = clipboard()
    let copied = 0
    await share(link, {navigator: {share: sheet, clipboard: board}, copied: () => { copied += 1 },
      failed: () => assert.fail("nothing failed")})

    assert.deepEqual(board.written, [link.url])
    assert.equal(copied, 1)
  }
})

// A second click while the sheet is open is refused as InvalidStateError. The open sheet goes on.
test("a share sheet that is already open copies nothing", async () => {
  const board = clipboard()
  const busy = Object.assign(new Error("open"), {name: "InvalidStateError"})
  await share(link, {navigator: {share: async () => { throw busy }, clipboard: board},
    copied: () => assert.fail("nothing copied"), failed: () => assert.fail("nothing failed")})

  assert.deepEqual(board.written, [])
})

// Outside a secure context there is neither a sheet nor a clipboard. A refused write fails too.
test("a link that cannot be copied says so", async () => {
  const refused = {writeText: async () => { throw new Error("denied") }}
  for (const navigator of [{}, undefined, {clipboard: refused}]) {
    let failed = 0
    await share(link, {navigator, copied: () => assert.fail("nothing copied"), failed: () => { failed += 1 }})
    assert.equal(failed, 1)
  }
})
