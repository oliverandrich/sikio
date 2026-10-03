// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {playerKey} from "./player_keys.mjs"

const press = (key, extra = {}) => ({key, target: {tagName: "BODY"}, ...extra})

test("the player's keys name what the player does", () => {
  assert.deepEqual(playerKey(press("p")), {name: "toggle"})
  assert.equal(playerKey(press(" ")), null, "Space stays the page's: Safari presses a focused button with it")
  assert.deepEqual(playerKey(press("ArrowLeft")), {name: "skip", by: -15})
  assert.deepEqual(playerKey(press("ArrowRight")), {name: "skip", by: 30})
  assert.deepEqual(playerKey(press("ArrowLeft", {shiftKey: true})), {name: "chapter", direction: -1})
  assert.deepEqual(playerKey(press("ArrowRight", {shiftKey: true})), {name: "chapter", direction: 1})
  assert.deepEqual(playerKey(press("u")), {name: "mute"})
  assert.deepEqual(playerKey(press("x")), {name: "fullscreen"})
  assert.equal(playerKey(press("j")), null)
  assert.equal(playerKey(press("ArrowUp")), null)
})

// Holding an arrow keeps skipping; holding the others would flicker.
test("only the skips repeat while a key is held", () => {
  assert.deepEqual(playerKey(press("ArrowRight", {repeat: true})), {name: "skip", by: 30})
  assert.equal(playerKey(press("p", {repeat: true})), null)
  assert.equal(playerKey(press("u", {repeat: true})), null)
})

// Keys typed into a field, or held with a modifier the browser uses, are not the player's.
test("a field or a browser shortcut keeps its keys", () => {
  for (const tagName of ["INPUT", "TEXTAREA", "SELECT"]) {
    assert.equal(playerKey(press("p", {target: {tagName}})), null)
  }
  assert.equal(playerKey(press("p", {target: {tagName: "DIV", isContentEditable: true}})), null)
  assert.equal(playerKey(press("p", {target: {tagName: "BUTTON", closest: selector => selector === "dialog" ? {} : null}})), null, "an open dialog keeps the page's keys")
  assert.equal(playerKey(press("ArrowLeft", {metaKey: true})), null)
  assert.equal(playerKey(press("ArrowLeft", {ctrlKey: true})), null)
  assert.equal(playerKey(press("ArrowLeft", {altKey: true})), null)
  assert.deepEqual(playerKey(press("p", {target: {tagName: "BUTTON"}})), {name: "toggle"})
})
