// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {movement} from "./reader_keys.mjs"

const press = (key, extra = {}) => ({key, target: {tagName: "BODY"}, ...extra})

test("j and k move, other keys do not", () => {
  assert.equal(movement(press("j")), "j")
  assert.equal(movement(press("k")), "k")
  assert.equal(movement(press("x")), null)
})

test("a key held with a modifier belongs to something else", () => {
  for (const modifier of ["metaKey", "ctrlKey", "altKey"])
    assert.equal(movement(press("k", {[modifier]: true})), null, modifier)
})

test("a key typed into a form control stays there", () => {
  for (const tagName of ["INPUT", "SELECT", "TEXTAREA"])
    assert.equal(movement(press("j", {target: {tagName}})), null, tagName)
  assert.equal(movement(press("j", {target: {tagName: "DIV", isContentEditable: true}})), null)
})
