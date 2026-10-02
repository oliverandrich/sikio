// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {closesSearch, readerKey, wantsFirst, reveal} from "./reader_keys.mjs"

const press = (key, extra = {}) => ({key, target: {tagName: "BODY"}, ...extra})

test("j and k move, m marks and f searches, other keys do not", () => {
  assert.equal(readerKey(press("j")), "j")
  assert.equal(readerKey(press("k")), "k")
  assert.equal(readerKey(press("m")), "m")
  assert.equal(readerKey(press("f")), "f")
  assert.equal(readerKey(press("x")), null)
})

// A player that has the keyboard uses letters of its own, so its keys are not the library's.
test("keys pressed into a player belong to the player", () => {
  assert.equal(readerKey(press("m", {target: {tagName: "AUDIO"}})), null)
  assert.equal(readerKey(press("j", {target: {tagName: "IFRAME"}})), null)
})

// Held down, m would mark and unmark in a stream. j and k may repeat; moving on is what they do.
test("a held m marks once, a held j keeps moving", () => {
  assert.equal(readerKey(press("m", {repeat: true})), null)
  assert.equal(readerKey(press("j", {repeat: true})), "j")
})

// Escape in the search field clears and folds it; elsewhere Escape belongs to someone else.
test("Escape closes the search only from inside it", () => {
  assert.equal(closesSearch(press("Escape", {target: {tagName: "INPUT", id: "search-input"}})), true)
  assert.equal(closesSearch(press("Escape", {target: {tagName: "INPUT", id: "other"}})), false)
  assert.equal(closesSearch(press("x", {target: {tagName: "INPUT", id: "search-input"}})), false)
})

// Beside the list there is room for the detail, so something is always shown there. On a phone
// the detail would cover the list, so nothing is chosen for the reader.
test("a wide screen with rows and nothing chosen asks for the first", () => {
  assert.equal(wantsFirst({wide: true, selected: "", rows: 3}), true)
  assert.equal(wantsFirst({wide: false, selected: "", rows: 3}), false)
  assert.equal(wantsFirst({wide: true, selected: "12", rows: 3}), false)
  assert.equal(wantsFirst({wide: true, selected: "", rows: 0}), false)
})

test("a key held with a modifier belongs to something else", () => {
  for (const modifier of ["metaKey", "ctrlKey", "altKey"])
    assert.equal(readerKey(press("k", {[modifier]: true})), null, modifier)
})

test("a key typed into a form control stays there", () => {
  for (const tagName of ["INPUT", "SELECT", "TEXTAREA"])
    assert.equal(readerKey(press("j", {target: {tagName}})), null, tagName)
  assert.equal(readerKey(press("j", {target: {tagName: "DIV", isContentEditable: true}})), null)
})

// The list's head stands over the top of the pane, so a row is only in view beneath it.
test("a row above the head's edge or below the pane's end is scrolled into view", () => {
  assert.equal(reveal({top: 100, bottom: 600, rowTop: 150, rowBottom: 250}), 0)
  assert.equal(reveal({top: 100, bottom: 600, rowTop: 60, rowBottom: 160}), -40)
  assert.equal(reveal({top: 100, bottom: 600, rowTop: 560, rowBottom: 660}), 60)
})
