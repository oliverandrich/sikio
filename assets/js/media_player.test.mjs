import {test} from "node:test"
import assert from "node:assert/strict"
import {createReporter, MediaPlayer} from "./media_player.mjs"

// The wording the server renders into the element's dataset. The tests assert on these, because
// what the player says is what somebody reads when playback stops.
const STRINGS = {
  stale: "Your progress changed elsewhere. Press Play to continue here.",
  saved: "Saved in Sikio.",
  disconnected: "Connection lost. Playback paused; your latest position will save when reconnected.",
  reconnectFirst: "Reconnect before switching or closing, so your place can be saved.",
  readyAudio: "Ready. Your place is saved as you listen.",
  readyAudioManual: "Ready. Press play in the audio controls.",
  audioFailed: "This audio could not be loaded.",
  readyYoutube: "Ready. Press play in the YouTube player.",
  youtubeUnavailable: "YouTube could not be loaded.",
  youtubeMissing: "This video is private or has been removed.",
  youtubeBlocked: "This video cannot be embedded. You can open it on YouTube.",
  youtubeOrigin: "YouTube could not identify this site.",
  youtubeUnplayable: "YouTube cannot play this video.",
  readyPeertube: "Ready. Your place is saved as you watch.",
  peertubeUnavailable: "This instance could not be reached."
}

function reporterFixture() {
  const calls = []
  let time = 10_000, position = 12, stopped = false, message = ""
  const reporter = createReporter({
    session: "session-1", now: () => time, strings: STRINGS,
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
    send: sample => calls.push(sample), stop() {}, message() {}, strings: STRINGS})
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
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {dataset: {kind: "podcast", session: "abc", position: "42", ...STRINGS},
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
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {dataset: {kind: "youtube", session: "video", position: "0", ...STRINGS},
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

// A PeerTube embed reports where it is about twice a second. That is the sample, and it is also
// what says the player exists: asked any earlier it answers zero, which would overwrite the
// place somebody left off at.
test("PeerTube reports its own position and does not save before it has one", async () => {
  const previous = {document: globalThis.document, window: globalThis.window}
  const doc = new EventTarget(), samples = [], said = [], posted = []
  const message = {set textContent(text) {said.push(text)}, get textContent() {return said.at(-1) ?? ""}}
  globalThis.document = doc
  globalThis.window = new EventTarget()

  const iframe = {src: "https://video.example.org/videos/embed/abc?api=1&start=42",
    contentWindow: {postMessage: data => posted.push(JSON.parse(data))}}
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {dataset: {kind: "peertube", session: "v", position: "42", ...STRINGS},
    querySelector: selector => selector === "[data-player-message]" ? message : selector === "iframe" ? iframe : null}),
    pushEvent: (_event, sample, reply) => {samples.push(sample); reply({saved: true})}}

  const fromEmbed = payload => {
    const event = new Event("message")
    event.data = JSON.stringify(payload)
    event.origin = "https://video.example.org"
    window.dispatchEvent(event)
  }

  try {
    hook.mounted()
    fromEmbed({method: "peertube::__ready", params: {type: "publish-request", publish: []}})
    assert.deepEqual(samples, [], "nothing is saved while the player has told us nothing")

    fromEmbed({method: "peertube::playbackStatusUpdate",
      params: {position: 42.5, duration: 100, playbackState: "playing"}})
    await Promise.resolve()

    assert.ok(said.some(text => /saved as you watch/.test(text)), "the reader is told the player is up")
    assert.equal(samples.at(-1)?.position, 42.5)
    assert.equal(samples.at(-1)?.duration, 100)

    fromEmbed({method: "peertube::playbackStatusChange", params: "ended"})
    await Promise.resolve()
    assert.equal(samples.at(-1).ended, true)

    hook.destroyed()
    assert.ok(posted.some(m => m.method === "peertube::pause"), "closing stops the instance's player")
  } finally {
    hook.destroyed()
    globalThis.document = previous.document
    globalThis.window = previous.window
  }
})

// Measured against a real instance: a video reaching its end reports `paused` and then `ended`
// a millisecond later. YouTube reports one state, so two saves leaving together is new here.
// The later one has to win, or finishing a video would leave it merely paused.
test("PeerTube pauses a millisecond before it ends, and the end is what counts", async () => {
  const previous = {document: globalThis.document, window: globalThis.window}
  const samples = [], said = []
  const message = {set textContent(text) {said.push(text)}, get textContent() {return said.at(-1) ?? ""}}
  globalThis.document = new EventTarget()
  globalThis.window = new EventTarget()

  const iframe = {src: "https://video.example.org/videos/embed/abc?api=1", contentWindow: {postMessage: () => {}}}
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {dataset: {kind: "peertube", session: "v", position: "0", ...STRINGS},
    querySelector: selector => selector === "[data-player-message]" ? message : selector === "iframe" ? iframe : null}),
    pushEvent: (_event, sample, reply) => {samples.push(sample); reply({saved: true})}}

  const fromEmbed = payload => {
    const event = new Event("message")
    event.data = JSON.stringify(payload)
    event.origin = "https://video.example.org"
    window.dispatchEvent(event)
  }

  try {
    hook.mounted()
    fromEmbed({method: "peertube::__ready", params: {type: "publish-request", publish: []}})
    fromEmbed({method: "peertube::playbackStatusUpdate", params: {position: 35, duration: 36, playbackState: "playing"}})
    await Promise.resolve()

    fromEmbed({method: "peertube::playbackStatusUpdate", params: {position: 36, duration: 36, playbackState: "paused"}})
    fromEmbed({method: "peertube::playbackStatusChange", params: "ended"})
    await Promise.resolve()
    await Promise.resolve()

    assert.equal(samples.at(-1).ended, true, "the end is the last word, not the pause before it")
  } finally {
    hook.destroyed()
    globalThis.document = previous.document
    globalThis.window = previous.window
  }
})
