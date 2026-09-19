import {test} from "node:test"
import assert from "node:assert/strict"
import {createReporter, MediaPlayer} from "./media_player.mjs"

function reporterFixture() {
  const calls = []
  let time = 10_000, position = 12, stopped = false, message = ""
  const reporter = createReporter({
    session: "session-1", now: () => time,
    read: () => ({position, duration: 100}),
    send: (sample, reply) => calls.push({sample, reply}),
    stop: () => { stopped = true }, message: value => { message = value }
  })
  return {reporter, calls, advance: value => {time += value}, seek: value => {position = value},
    stopped: () => stopped, message: () => message}
}

test("progress is throttled, but pause/seek/end flush immediately and serialize replies", () => {
  const f = reporterFixture()
  f.reporter.save()
  assert.equal(f.calls.length, 1)
  assert.deepEqual(f.calls[0].sample, {session: "session-1", sequence: 1, position: 12, duration: 100, ended: false})
  f.calls[0].reply({saved: true})
  f.advance(1000)
  f.reporter.save()
  assert.equal(f.calls.length, 1)
  f.seek(30)
  f.reporter.save(false, true)
  f.seek(100)
  f.reporter.save(true, true)
  assert.equal(f.calls.length, 2)
  f.calls[1].reply({saved: true})
  assert.equal(f.calls[2].sample.ended, true)
  assert.equal(f.calls[2].sample.position, 100)
  assert.equal(f.calls[2].sample.sequence, 3)
})

test("stale progress pauses the player and cannot send again", () => {
  const f = reporterFixture()
  f.reporter.save()
  assert.equal(f.calls.length, 1)
  f.calls[0].reply({saved: false})
  assert.equal(f.stopped(), true)
  assert.match(f.message(), /changed/)
  f.reporter.save(true, true)
  assert.equal(f.calls.length, 1)
})

test("reconnect retries the latest position and ignores a late pre-disconnect reply", () => {
  const f = reporterFixture()
  f.reporter.save()
  assert.equal(f.calls.length, 1)
  f.reporter.disconnect()
  assert.equal(f.stopped(), true)
  f.seek(18)
  f.reporter.save(false, true)
  assert.equal(f.calls.length, 1)
  f.reporter.reconnect()
  assert.equal(f.calls[1].sample.position, 18)
  f.calls[0].reply({saved: false})
  assert.doesNotMatch(f.message(), /changed/)
  f.calls[1].reply({saved: true})
  assert.match(f.message(), /Saved/)
})

test("unknown live duration is omitted and invalid positions are not persisted", () => {
  const calls = []
  let position = NaN
  const reporter = createReporter({session: "live", read: () => ({position, duration: Infinity}),
    send: sample => calls.push(sample), stop() {}, message() {}})
  reporter.save(false, true)
  assert.equal(calls.length, 0)
  position = 25
  reporter.save(false, true)
  assert.equal(calls.length, 1)
  assert.equal(calls[0].duration, null)
})

test("audio restores after metadata, offers speed control, saves end and cleans up", () => {
  const audio = new EventTarget()
  Object.assign(audio, {currentTime: 0, duration: 100, readyState: 0, playbackRate: 1,
    play: () => Promise.resolve(), pause() {this.paused = true}, load() {}, removeAttribute() {}})
  const speed = new EventTarget()
  speed.value = "1.5"
  const message = {textContent: ""}
  const doc = new EventTarget()
  doc.hidden = false
  const previousDocument = globalThis.document
  globalThis.document = doc
  const samples = []
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {dataset: {kind: "podcast", session: "abc", position: "42"},
    querySelector: selector => ({audio, "#playback-speed": speed, "[data-player-message]": message}[selector])}),
    pushEvent: (_event, sample, reply) => {samples.push(sample); reply({saved: true})}}
  try {
    hook.mounted()
    assert.equal(audio.currentTime, 0)
    audio.readyState = 1
    audio.dispatchEvent(new Event("loadedmetadata"))
    assert.equal(audio.currentTime, 42)
    speed.dispatchEvent(new Event("change"))
    assert.equal(audio.playbackRate, 1.5)
    audio.currentTime = 100
    audio.dispatchEvent(new Event("ended"))
    assert.equal(samples.at(-1).ended, true)
    hook.destroyed()
    assert.equal(audio.paused, true)
    const count = samples.length
    audio.dispatchEvent(new Event("timeupdate"))
    assert.equal(samples.length, count)
  } finally {
    hook.destroyed()
    globalThis.document = previousDocument
  }
})

test("an end event survives a disconnect before its acknowledgement", () => {
  const f = reporterFixture()
  f.seek(100)
  f.reporter.save(true, true)
  f.reporter.disconnect()
  f.reporter.reconnect()
  assert.equal(f.calls[1].sample.ended, true)
})

test("YouTube saves a seek while paused, maps errors and destroys the iframe", async () => {
  const previous = {document: globalThis.document, window: globalThis.window, interval: globalThis.setInterval}
  const doc = new EventTarget(), message = {textContent: ""}, samples = []
  let events, poll, position = 0, destroyed = false
  globalThis.document = doc
  globalThis.window = {YT: {PlayerState: {PLAYING: 1, PAUSED: 2, ENDED: 0}, Player: class {
    constructor(_frame, options) {events = options.events}
    getCurrentTime() {return position}
    getDuration() {return 100}
    getPlayerState() {return 2}
    pauseVideo() {}
    destroy() {destroyed = true}
  }}}
  globalThis.setInterval = callback => {poll = callback; return 0}
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {dataset: {kind: "youtube", session: "video", position: "0"},
    querySelector: selector => selector === "[data-player-message]" ? message : selector === "iframe" ? {} : null}),
    pushEvent: (_event, sample, reply) => {samples.push(sample); reply({saved: true})}}
  try {
    hook.mounted()
    await Promise.resolve()
    events.onReady()
    poll()
    position = 30
    poll()
    assert.equal(samples.at(-1)?.position, 30)
    events.onError({data: 101})
    assert.match(message.textContent, /cannot be embedded/)
    events.onStateChange({data: 0})
    assert.equal(samples.at(-1).ended, true)
    hook.destroyed()
    assert.equal(destroyed, true)
  } finally {
    hook.destroyed()
    globalThis.document = previous.document
    globalThis.window = previous.window
    globalThis.setInterval = previous.interval
  }
})

test("finish waits for an acknowledged final sample before allowing player replacement", () => {
  const f = reporterFixture(), results = []
  f.reporter.save()
  f.seek(19)
  f.reporter.finish(saved => results.push(saved))
  assert.equal(f.stopped(), true)
  assert.deepEqual(results, [])
  f.calls[0].reply({saved: true})
  assert.equal(f.calls[1].sample.position, 19)
  assert.deepEqual(results, [])
  f.calls[1].reply({saved: true})
  assert.deepEqual(results, [true])
})

test("finish refuses a switch while disconnected and can be retried", () => {
  const f = reporterFixture(), results = []
  f.reporter.disconnect()
  f.reporter.finish(saved => results.push(saved))
  assert.deepEqual(results, [false])
  f.reporter.reconnect()
  f.calls[0].reply({saved: true})
  f.reporter.finish(saved => results.push(saved))
  assert.equal(f.calls.length, 2)
  f.calls[1].reply({saved: true})
  assert.deepEqual(results, [false, true])
})
