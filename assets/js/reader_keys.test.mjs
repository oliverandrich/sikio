// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {closesSearch, readerKey, wantsFirst} from "./reader_keys.mjs"

const press = (key, extra = {}) => ({key, target: {tagName: "BODY"}, ...extra})

test("j and k move, m marks and f searches, other keys do not", () => {
  assert.equal(readerKey(press("j")), "j")
  assert.equal(readerKey(press("k")), "k")
  assert.equal(readerKey(press("m")), "m")
  assert.equal(readerKey(press("f")), "f")
  assert.equal(readerKey(press("x")), null)
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
