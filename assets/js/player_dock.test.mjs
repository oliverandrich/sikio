// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {PlayerDock, rejoinParams} from "./player_dock.mjs"

function fixture() {
  const previousWindow = globalThis.window
  globalThis.window = new EventTarget()
  const media = new EventTarget(), calls = []
  let finish
  media.addEventListener("sikio:flush", event => {finish = event.detail.done})
  const hook = {...PlayerDock, el: {dataset: {entryId: "1"}, querySelector: selector => selector.includes("MediaPlayer") ? media : null},
    pushEvent: (event, params, reply) => {calls.push({event, params}); reply({})}}
  hook.mounted()
  return {hook, calls, finish: saved => {assert.equal(typeof finish, "function", "player must request a flush"); finish(saved)},
    play: id => window.dispatchEvent(new CustomEvent("sikio:play", {detail: {id}})),
    close: () => window.dispatchEvent(new CustomEvent("sikio:close-player")),
    cleanup: () => {hook.destroyed(); globalThis.window = previousWindow}}
}

test("changing episodes waits for the current player's save before replacing it", () => {
  const f = fixture()
  try {
    f.play(2)
    assert.equal(f.calls.length, 0)
    f.finish(true)
    assert.deepEqual(f.calls, [{event: "start", params: {id: 2}}])
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
