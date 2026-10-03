// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {PlayerDock, rejoinParams} from "./player_dock.mjs"

function fixture({player: playing = true, start = null} = {}) {
  const previousWindow = globalThis.window, previousDocument = globalThis.document
  globalThis.window = new EventTarget()
  const media = new EventTarget(), calls = [], focused = []
  const panel = {focus: () => focused.push("panel")}
  const frame = {tagName: "IFRAME"}
  let finish
  media.addEventListener("sikio:flush", event => {finish = event.detail.done})
  const el = {dataset: {entryId: "1"}, contains: node => node === frame,
    querySelector: selector => selector.includes("MediaPlayer") ? (playing ? media : null)
      : selector === "#player-panel" ? panel : null}
  const state = {frameFocused: false}
  globalThis.document = {get activeElement() { return state.frameFocused ? frame : null },
    getElementById: id => id === "start-playback" ? start : null}
  const hook = {...PlayerDock, el,
    pushEvent: (event, params, reply) => {calls.push({event, params}); reply({})}}
  hook.mounted()
  return {hook, calls, focused, set frameFocused(value) { state.frameFocused = value }, finish: saved => {assert.equal(typeof finish, "function", "player must request a flush"); finish(saved)},
    play: (id, position) => window.dispatchEvent(new CustomEvent("sikio:play", {detail: {id, position}})),
    close: () => window.dispatchEvent(new CustomEvent("sikio:close-player")),
    cleanup: () => {hook.destroyed(); globalThis.window = previousWindow; globalThis.document = previousDocument}}
}

test("changing episodes waits for the current player's save before replacing it", () => {
  const f = fixture()
  try {
    f.play(2)
    assert.equal(f.calls.length, 0)
    f.finish(true)
    assert.deepEqual(f.calls, [{event: "start", params: {id: 2, position: null}}])
  } finally {f.cleanup()}
})

// A chapter of the item that already plays moves its player there rather than starting anew.
test("a place for the item that plays moves its player", () => {
  const f = fixture()
  const seeks = []
  const media = f.hook.el.querySelector("[phx-hook='MediaPlayer']")
  media.addEventListener("sikio:seek", event => seeks.push(event.detail.position))
  try {
    f.play(1, 118)
    assert.deepEqual(seeks, [118])
    assert.deepEqual(f.calls, [], "nothing is started again")
    f.play(1)
    assert.deepEqual(seeks, [118], "play alone does not move it")
  } finally {f.cleanup()}
})

// The card's player names the place it was dragged or skipped to.
test("a start carries the place to begin at", () => {
  const f = fixture()
  try {
    f.play(2, 600)
    f.finish(true)
    assert.deepEqual(f.calls, [{event: "start", params: {id: 2, position: 600}}])
  } finally {f.cleanup()}
})

// The page keeps the keyboard: a started player does not take the focus.
test("a started player leaves the focus where it was", () => {
  const f = fixture()
  try {
    f.play(2)
    f.finish(true)
    assert.deepEqual(f.focused, [])
  } finally {f.cleanup()}
})

const keydown = (key, extra = {}) =>
  Object.assign(new Event("keydown", {cancelable: true}), {key, ...extra})

// The player's keys work on every page, through whichever player plays.
test("a player's key reaches the player that plays and goes no further", () => {
  const f = fixture()
  const commands = []
  f.hook.el.querySelector("[phx-hook='MediaPlayer']")
    .addEventListener("sikio:command", event => commands.push(event.detail))
  try {
    const play = keydown("p")
    window.dispatchEvent(play)
    window.dispatchEvent(keydown("ArrowRight"))
    window.dispatchEvent(keydown("j"))
    assert.deepEqual(commands, [{name: "toggle"}, {name: "skip", by: 30}])
    assert.equal(play.defaultPrevented, true)
  } finally {f.cleanup()}
})

test("without a player the keys are the page's", () => {
  const f = fixture({player: false})
  try {
    const arrow = keydown("ArrowRight")
    const play = keydown("p")
    window.dispatchEvent(arrow)
    window.dispatchEvent(play)
    assert.equal(arrow.defaultPrevented, false)
    assert.equal(play.defaultPrevented, false, "nothing to start without an open item")
  } finally {f.cleanup()}
})

// Without a player, p starts the item that is open, as its play button does.
test("without a player p starts the open item", () => {
  let pressed = 0
  const f = fixture({player: false, start: {click: () => pressed++}})
  try {
    const play = keydown("p")
    window.dispatchEvent(play)
    window.dispatchEvent(keydown("ArrowRight"))
    assert.equal(pressed, 1)
    assert.equal(play.defaultPrevented, true)
  } finally {f.cleanup()}
})

// A click into a video's frame takes the keyboard there, where the page cannot hear it. The
// page takes it back at once and gives it to the panel.
test("the focus comes back from the player's frame", async () => {
  const f = fixture()
  try {
    f.frameFocused = true
    window.dispatchEvent(new Event("blur"))
    await new Promise(resolve => setTimeout(resolve, 0))
    assert.deepEqual(f.focused, ["panel"])
  } finally {f.cleanup()}
})

// Tab moves into the frame on purpose, to reach the embed's own controls; a click does not.
test("the keyboard that tabs into the player's frame stays there", async () => {
  const f = fixture()
  const settle = () => new Promise(resolve => setTimeout(resolve, 0))
  try {
    f.frameFocused = true
    window.dispatchEvent(keydown("Tab"))
    window.dispatchEvent(new Event("blur"))
    await settle()
    assert.deepEqual(f.focused, [])
    window.dispatchEvent(new Event("pointerdown"))
    window.dispatchEvent(new Event("blur"))
    await settle()
    assert.deepEqual(f.focused, ["panel"])
  } finally {f.cleanup()}
})

test("same item stays playing, close flushes, failed saves keep the player", () => {
  const f = fixture()
  try {
    f.play(1)
    assert.equal(f.calls.length, 0)
    f.close()
    f.finish(false)
    assert.equal(f.calls.length, 0)
    f.close()
    f.finish(true)
    assert.deepEqual(f.calls, [{event: "close", params: {}}])
  } finally {f.cleanup()}
})

test("a rejoin names the player the dock still holds, and nothing without one", () => {
  const view = media => ({querySelector: selector => selector === "#player-control"
    ? {dataset: {entryId: "7"}, querySelector: inner => inner === "[phx-hook=MediaPlayer]" ? media : null}
    : null})
  assert.deepEqual(rejoinParams(view({dataset: {session: "abc"}})),
    {player_entry: "7", player_session: "abc"})
  assert.deepEqual(rejoinParams(view(null)), {})
  assert.deepEqual(rejoinParams({querySelector: () => null}), {})
  assert.deepEqual(rejoinParams(undefined), {}, "the socket also asks without a view")
})
