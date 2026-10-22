// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {captureLinkToken, TokenLink, reloadOnOtherLink} from "./token_link.mjs"

// A window with only what the module reads: the hook element, the address, history and storage.
function fakeWindow({hash = "", page = "invitation-link", storage = new Map()} = {}) {
  const calls = {replaced: [], reloaded: 0, listeners: {}}

  const win = {
    document: {getElementById: id => (page && id === page ? {id} : null)},
    location: {pathname: "/invite", search: "", hash, reload: () => calls.reloaded++},
    history: {state: null, replaceState: (_state, _title, url) => calls.replaced.push(url)},
    sessionStorage: storage && {
      setItem: (key, value) => storage.set(key, value),
      getItem: key => storage.get(key) ?? null,
      removeItem: key => storage.delete(key),
    },
    addEventListener: (name, fun) => (calls.listeners[name] = fun),
  }

  globalThis.window = win
  return {win, calls, storage}
}

function hook(id = "invitation-link") {
  const pushed = []
  const handlers = {}
  const instance = Object.assign(Object.create(TokenLink), {
    el: {id},
    pushEvent: (name, payload) => pushed.push([name, payload]),
    handleEvent: (name, fun) => (handlers[name] = fun),
  })
  return {instance, pushed, handlers}
}

// The join sends the page's URL, so the fragment leaves the address before the socket connects.
test("the token leaves the address and stays in the tab", () => {
  const {calls, storage} = fakeWindow({hash: "#abc_DEF-123"})

  assert.equal(captureLinkToken(), "abc_DEF-123")
  assert.deepEqual(calls.replaced, ["/invite"])
  assert.equal(storage.get("invitation-token"), "abc_DEF-123")
})

test("another page keeps its fragment", () => {
  const {calls} = fakeWindow({hash: "#notes", page: null})

  assert.equal(captureLinkToken(), "")
  assert.deepEqual(calls.replaced, [])
})

// Tokens are base64url, so a malformed percent sequence is not decoded and cannot throw.
test("a fragment is taken as it is, even one that looks encoded", () => {
  fakeWindow({hash: "#abc%E0%A4"})

  assert.equal(captureLinkToken(), "abc%E0%A4")
})

test("a tab without storage still opens the invitation it was given", () => {
  const {win, calls} = fakeWindow({hash: "#tok", storage: null})
  win.sessionStorage = {setItem: () => { throw new Error("denied") }, getItem: () => { throw new Error("denied") }}

  assert.equal(captureLinkToken(), "tok")
  assert.deepEqual(calls.replaced, ["/invite"])
})

test("the hook sends the token after the join, and again after a rejoin", () => {
  fakeWindow({hash: "#tok"})
  captureLinkToken()
  const {instance, pushed} = hook()

  instance.mounted()
  instance.reconnected()

  assert.deepEqual(pushed, [["invitation-token", {token: "tok"}], ["invitation-token", {token: "tok"}]])
})

// A reload has no fragment any more; the tab's storage still holds the token.
test("after a reload the hook sends the token the tab kept", () => {
  const storage = new Map([["invitation-token", "kept"]])
  fakeWindow({storage})
  captureLinkToken()
  const {instance, pushed} = hook()

  instance.mounted()

  assert.deepEqual(pushed, [["invitation-token", {token: "kept"}]])
})

test("a token the server does not know is forgotten", () => {
  const {storage} = fakeWindow({hash: "#gone"})
  captureLinkToken()
  const {instance, handlers, pushed} = hook()

  instance.mounted()
  handlers["invitation-token-forget"]()
  instance.reconnected()

  assert.equal(storage.has("invitation-token"), false)
  assert.deepEqual(pushed.at(-1), ["invitation-token", {token: ""}])
})

// A second link pasted into the same tab changes only the fragment, which loads nothing.
test("another link in the same tab reloads the invitation page", () => {
  const {calls} = fakeWindow()

  reloadOnOtherLink()
  calls.listeners.hashchange()

  assert.equal(calls.reloaded, 1)
})

// The address confirmation link carries its token the same way, under its own names.
test("an address link keeps its token apart from an invitation's", () => {
  const {calls, storage} = fakeWindow({hash: "#addr", page: "address-link"})

  assert.equal(captureLinkToken(), "addr")
  assert.deepEqual(calls.replaced, ["/invite"])
  assert.equal(storage.get("address-token"), "addr")
  assert.equal(storage.has("invitation-token"), false)

  const {instance, pushed} = hook("address-link")
  instance.mounted()
  assert.deepEqual(pushed, [["address-token", {token: "addr"}]])
})

// A token caught on one page is not pushed as the other page's token.
test("a held token belongs to the page it was caught on", () => {
  fakeWindow({hash: "#addr", page: "address-link"})
  captureLinkToken()

  const {instance, pushed} = hook("invitation-link")
  instance.mounted()
  assert.deepEqual(pushed, [["invitation-token", {token: ""}]])
})
