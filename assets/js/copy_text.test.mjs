// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {copyText, CopyText} from "./copy_text.mjs"

const clipboard = () => {
  const written = []
  return {written, navigator: {clipboard: {writeText: async text => written.push(text)}}}
}

test("text goes to the clipboard and the copy answers so", async () => {
  const {written, navigator} = clipboard()

  assert.equal(await copyText("https://sikio.example.org/invite#tok", navigator), true)
  assert.deepEqual(written, ["https://sikio.example.org/invite#tok"])
})

// Outside a secure context there is no clipboard, and a browser may refuse the write.
test("no clipboard, or a refused write, answers false", async () => {
  assert.equal(await copyText("x", {}), false)
  assert.equal(await copyText("x", {clipboard: {writeText: async () => { throw new Error("denied") }}}), false)
})

// Node has a read-only `navigator` of its own.
const useNavigator = navigator =>
  Object.defineProperty(globalThis, "navigator", {value: navigator, configurable: true})

// The button names the element to copy and the status line; the status says what happened.
function page({statusLine = true} = {}) {
  const listeners = {}
  const status = {textContent: ""}
  const button = {
    disabled: false,
    dataset: {copyText: "https://sikio.example.org/invite#tok", copyStatus: "copy-link-status",
      copySuccess: "Link copied.", copyError: "Copying was blocked."},
    addEventListener: (name, fun) => (listeners[name] = fun),
    removeEventListener: name => delete listeners[name],
  }
  const elements = statusLine ? {"copy-link-status": status} : {}
  globalThis.document = {getElementById: id => elements[id] ?? null}
  return {listeners, status, button}
}

// LiveView's `js()` sets attributes so that a patch keeps them. The stub writes the dataset.
function withJs(el) {
  const name = attr => attr.replace(/^data-/, "").replace(/-(\w)/g, (_, c) => c.toUpperCase())
  const js = {
    setAttribute: (target, attr, value) => (target.dataset[name(attr)] = value),
    removeAttribute: (target, attr) => delete target.dataset[name(attr)],
  }
  return Object.assign(Object.create(CopyText), {el, js: () => js})
}

// The page that has gone away meanwhile leaves no status line, and nothing breaks.
test("a status line that is gone by the time the copy answers is skipped", async () => {
  const {listeners, button} = page({statusLine: false})
  const {navigator} = clipboard()
  useNavigator(navigator)
  const hook = withJs(button)

  hook.mounted()
  await listeners.click()
  hook.destroyed()
})

test("a click copies the button's text and reports it", async () => {
  const {listeners, status, button} = page()
  const {written, navigator} = clipboard()
  useNavigator(navigator)
  const hook = withJs(button)

  hook.mounted()
  await listeners.click()
  hook.destroyed()

  assert.deepEqual(written, ["https://sikio.example.org/invite#tok"])
  assert.equal(status.textContent, "Link copied.")
  assert.equal("disabled" in button.dataset, false)
  // The icon turns into a check while `data-copied` is set.
  assert.equal(button.dataset.copied, "")
})

test("a refused copy says to copy by hand", async () => {
  const {listeners, status, button} = page()
  useNavigator({})
  const hook = withJs(button)

  hook.mounted()
  await listeners.click()
  hook.destroyed()

  assert.equal(status.textContent, "Copying was blocked.")
  assert.equal("copied" in button.dataset, false)
})
