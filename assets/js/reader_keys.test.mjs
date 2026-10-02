// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {readerKey} from "./reader_keys.mjs"

const press = (key, extra = {}) => ({key, target: {tagName: "BODY"}, ...extra})

test("j and k move and m marks, other keys do not", () => {
  assert.equal(readerKey(press("j")), "j")
  assert.equal(readerKey(press("k")), "k")
  assert.equal(readerKey(press("m")), "m")
  assert.equal(readerKey(press("x")), null)
})

// Held down, m would mark and unmark in a stream. j and k may repeat; moving on is what they do.
test("a held m marks once, a held j keeps moving", () => {
  assert.equal(readerKey(press("m", {repeat: true})), null)
  assert.equal(readerKey(press("j", {repeat: true})), "j")
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
