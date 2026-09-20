// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {connect} from "./peertube_embed.mjs"

const ORIGIN = "https://video.example.org"

// The embed is another window that answers only through postMessage. This is that window,
// speaking the format jschannel documents: JSON strings, methods carrying the channel's scope.
function fixture() {
  const previousWindow = globalThis.window
  globalThis.window = new EventTarget()
  const sent = []
  const iframe = {contentWindow: {postMessage: (data, origin) => sent.push({data: JSON.parse(data), origin})}}

  const fromEmbed = payload => {
    const event = new Event("message")
    event.data = JSON.stringify(payload)
    event.origin = ORIGIN
    event.source = iframe.contentWindow
    window.dispatchEvent(event)
  }

  const status = [], errors = []
  const player = connect(iframe, {origin: ORIGIN, onStatus: s => status.push(s), onError: e => errors.push(e)})

  return {player, sent, status, errors, fromEmbed,
    greet: () => fromEmbed({method: "peertube::__ready", params: {type: "publish-request", publish: []}}),
    request: (id, method, params) => fromEmbed({id, method: `peertube::${method}`, params}),
    answer: (id, result) => fromEmbed({id, result}),
    cleanup: () => {player.destroy(); globalThis.window = previousWindow}}
}

test("the handshake is answered before anything else is said", () => {
  const f = fixture()
  try {
    assert.deepEqual(f.sent, [], "nothing is said before the embed greets us")
    f.greet()
    assert.equal(f.sent[0].origin, ORIGIN)
    assert.equal(f.sent[0].data.method, "peertube::__ready", "the reply comes before any question")
    assert.equal(f.sent[0].data.params.type, "publish-reply")
  } finally {f.cleanup()}
})

test("a request waits for the handshake and then carries an id of its own", async () => {
  const f = fixture()
  try {
    const asked = f.player.call("getCurrentTime")
    assert.deepEqual(f.sent, [], "a request before the handshake is held, not dropped")

    f.greet()
    const request = f.sent.find(m => m.data.method === "peertube::getCurrentTime")
    assert.ok(request, "the held request leaves once the channel is ready")

    f.answer(request.data.id, 42.5)
    assert.equal(await asked, 42.5)
  } finally {f.cleanup()}
})

test("two requests are answered by id rather than by order", async () => {
  const f = fixture()
  try {
    f.greet()
    const first = f.player.call("getCurrentTime")
    const second = f.player.call("isPlaying")
    const a = f.sent.find(m => m.data.method === "peertube::getCurrentTime")
    const b = f.sent.find(m => m.data.method === "peertube::isPlaying")

    f.answer(b.data.id, true)
    f.answer(a.data.id, 7)

    assert.equal(await first, 7)
    assert.equal(await second, true)
  } finally {f.cleanup()}
})

test("progress and state arrive as notifications, not as answers", () => {
  const f = fixture()
  try {
    f.greet()
    f.fromEmbed({method: "peertube::playbackStatusUpdate", params: {position: 3, duration: 36, playbackState: "playing"}})
    f.fromEmbed({method: "peertube::playbackStatusChange", params: "ended"})

    assert.deepEqual(f.status, [{position: 3, duration: 36, playbackState: "playing"}, "ended"])
  } finally {f.cleanup()}
})

test("an error answer rejects the request that asked", async () => {
  const f = fixture()
  try {
    f.greet()
    const asked = f.player.call("getCurrentTime")
    const request = f.sent.find(m => m.data.method === "peertube::getCurrentTime")
    f.fromEmbed({id: request.data.id, error: "runtime_error", message: "nope"})

    await assert.rejects(asked)
  } finally {f.cleanup()}
})

// Another window may post anything it likes. Only the instance holding this video is listened to.
test("a message from anywhere else is ignored", () => {
  const f = fixture()
  try {
    const event = new Event("message")
    event.data = JSON.stringify({method: "peertube::__ready", params: {type: "publish-request", publish: []}})
    event.origin = "https://evil.example.org"
    window.dispatchEvent(event)

    assert.deepEqual(f.sent, [], "a stranger cannot complete the handshake")
  } finally {f.cleanup()}
})

test("nothing is said after the channel is destroyed", () => {
  const f = fixture()
  try {
    f.greet()
    const before = f.sent.length
    f.player.destroy()
    f.player.call("getCurrentTime").catch(() => {})
    assert.equal(f.sent.length, before)
  } finally {f.cleanup()}
})

// Readiness is the hook's business, and it takes it from the position the embed reports. This
// asked the embed twice a second from the handshake onwards, which for a video somebody loads
// and never starts is a question without an end.
test("nothing is asked on a timer", async () => {
  const f = fixture()
  try {
    f.greet()
    const before = f.sent.length
    await new Promise(resolve => setTimeout(resolve, 30))
    assert.equal(f.sent.length, before, "silence after the handshake stays silence")
  } finally {f.cleanup()}
})

// The embed calls this side once. An unanswered call leaves it waiting on a promise of its own.
test("an inbound request is answered, not mistaken for an answer", () => {
  const f = fixture()
  try {
    f.greet()
    f.request(11, "ready", true)

    const reply = f.sent.find(m => m.data.id === 11)
    assert.ok(reply, "the embed is answered so its own call does not hang")
    assert.equal(reply.data.method, undefined)
  } finally {f.cleanup()}
})
