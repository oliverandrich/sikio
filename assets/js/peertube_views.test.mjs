// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {createViews} from "./peertube_views.mjs"

function fixture() {
  let time = 0
  const sent = []
  const views = createViews({send: body => sent.push(body), now: () => time, session: "s1"})
  return {views, sent, wait: ms => { time += ms }}
}

test("playback reports at once and then every ten seconds", () => {
  const {views, sent, wait} = fixture()
  views.playing(12.7)
  assert.deepEqual(sent, [{currentTime: 12, sessionId: "s1"}])
  wait(9999)
  views.playing(22)
  assert.equal(sent.length, 1)
  wait(1)
  views.playing(22.4)
  assert.deepEqual(sent.at(-1), {currentTime: 22, sessionId: "s1"})
})

test("the report after a seek says so, once", () => {
  const {views, sent, wait} = fixture()
  views.playing(0)
  views.sought()
  wait(10000)
  views.playing(300)
  assert.deepEqual(sent.at(-1), {currentTime: 300, sessionId: "s1", viewEvent: "seek"})
  wait(10000)
  views.playing(310)
  assert.deepEqual(sent.at(-1), {currentTime: 310, sessionId: "s1"})
})
