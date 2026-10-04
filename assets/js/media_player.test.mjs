// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {createReporter, MediaPlayer} from "./media_player.mjs"

// The wording the server renders into the element's dataset. The tests assert on these, because
// what the player says is what somebody reads when playback stops.
const STRINGS = {
  stale: "Your progress changed elsewhere. Press Play to continue here.",
  disconnected: "Connection lost. Playback paused; your latest position will save when reconnected.",
  reconnectFirst: "Reconnect before switching or closing, so your place can be saved.",
  readyAudioManual: "The browser did not start it. Press play.",
  audioFailed: "This audio could not be loaded.",
  youtubeUnavailable: "YouTube could not be loaded.",
  youtubeMissing: "This video is private or has been removed.",
  youtubeBlocked: "This video cannot be embedded. You can open it on YouTube.",
  youtubeOrigin: "YouTube could not identify this site.",
  youtubeUnplayable: "YouTube cannot play this video.",
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
    stopped: () => stopped, message: () => message, say: value => {message = value}}
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
  assert.equal(f.message(), "", "a save clears the warning and says nothing of its own")
})

// The player's own hint, such as press play after a refused autoplay, is not the reporter's to
// clear. A save only takes back a warning the reporter gave itself.
test("a save leaves a message it did not give", () => {
  const f = reporterFixture()
  f.reporter.save()
  f.calls[0].reply({saved: true})
  assert.equal(f.calls.length, 1)
  assert.equal(f.message(), "", "the first save of a working player says nothing")
  f.reporter.disconnect()
  f.reporter.reconnect()
  f.calls[1].reply({saved: true})
  assert.equal(f.message(), "")
  f.say("Press play")
  f.advance(10_000)
  f.reporter.save()
  f.calls[2].reply({saved: true})
  assert.equal(f.message(), "Press play")
})

// A paused PeerTube embed keeps reporting twice a second, and each report asks for a save. A
// switch that waited for the queue to run dry would never end, and no button would work again.
test("finishing ends although the player keeps asking to save", () => {
  const f = reporterFixture()
  const results = []
  f.reporter.finish(saved => results.push(saved))
  for (let n = 0; n < 5 && results.length === 0; n++) {
    f.reporter.save(false, true)
    f.calls.at(-1).reply({saved: true})
  }
  assert.deepEqual(results, [true])
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

// The page's keys drive the audio: play and pause, the skips, the chapters and the sound.
test("audio follows the player's keys", () => {
  const calls = []
  const audio = new EventTarget()
  Object.assign(audio, {dataset: {}, currentTime: 0, duration: 400, readyState: 0, playbackRate: 1,
    paused: true, muted: false,
    play() { calls.push("play"); this.paused = false; return Promise.resolve() },
    pause() { calls.push("pause"); this.paused = true }, load() {}, removeAttribute() {}})
  const previousDocument = globalThis.document
  globalThis.document = Object.assign(new EventTarget(), {hidden: false})
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}}, 
    dataset: {kind: "podcast", session: "abc", position: "0", chapters: "[0,118,291]", ...STRINGS},
    querySelector: selector => ({audio, "[data-player-message]": {textContent: ""}}[selector])}),
    pushEvent: (_event, _sample, reply) => reply({saved: true})}
  const command = detail => hook.el.dispatchEvent(new CustomEvent("sikio:command", {detail}))
  try {
    hook.mounted()
    audio.readyState = 1
    audio.dispatchEvent(new Event("loadedmetadata"))
    // Restoring the place starts the audio, so the first press pauses it and the next plays.
    command({name: "toggle"})
    command({name: "toggle"})
    assert.deepEqual(calls, ["play", "pause", "play"])
    command({name: "skip", by: 30})
    assert.equal(audio.currentTime, 30)
    command({name: "skip", by: -15})
    assert.equal(audio.currentTime, 15)
    command({name: "chapter", direction: 1})
    assert.equal(audio.currentTime, 118)
    command({name: "chapter", direction: 1})
    assert.equal(audio.currentTime, 291)
    command({name: "chapter", direction: 1})
    assert.equal(audio.currentTime, 291, "past the last chapter it stays")
    audio.currentTime = 300
    command({name: "chapter", direction: -1})
    assert.equal(audio.currentTime, 291, "back goes to the start of the chapter that plays")
    audio.currentTime = 292
    command({name: "chapter", direction: -1})
    assert.equal(audio.currentTime, 118, "just after a start, back goes one further")
    command({name: "mute"})
    assert.equal(audio.muted, true)
    command({name: "mute"})
    assert.equal(audio.muted, false)
    // The page may learn the chapters later, from a file or a measured length.
    hook.el.dataset.chapters = "[0,50]"
    audio.currentTime = 10
    command({name: "chapter", direction: 1})
    assert.equal(audio.currentTime, 50, "the chapters the page names now")
  } finally {
    hook.destroyed()
    globalThis.document = previousDocument
  }
})

// A key before the audio knows itself moves from the saved place, not from zero.
test("a skip before the audio is ready starts from the saved place", () => {
  const audio = new EventTarget()
  Object.assign(audio, {dataset: {}, currentTime: 0, duration: 4000, readyState: 0, playbackRate: 1,
    paused: true, muted: false, play() { this.paused = false; return Promise.resolve() },
    pause() { this.paused = true }, load() {}, removeAttribute() {}})
  const previousDocument = globalThis.document
  globalThis.document = Object.assign(new EventTarget(), {hidden: false})
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}}, 
    dataset: {kind: "podcast", session: "abc", position: "1200", ...STRINGS},
    querySelector: selector => ({audio, "[data-player-message]": {textContent: ""}}[selector])}),
    pushEvent: (_event, _sample, reply) => reply({saved: true})}
  try {
    hook.mounted()
    hook.el.dispatchEvent(new CustomEvent("sikio:command", {detail: {name: "skip", by: 30}}))
    audio.readyState = 1
    audio.dispatchEvent(new Event("loadedmetadata"))
    assert.equal(audio.currentTime, 1230)
  } finally {
    hook.destroyed()
    globalThis.document = previousDocument
  }
})

test("audio restores after metadata, saves end and cleans up", () => {
  const audio = new EventTarget()
  Object.assign(audio, {dataset: {}, currentTime: 0, duration: 100, readyState: 0, playbackRate: 1,
    play: () => Promise.resolve(), pause() {this.paused = true}, load() {}, removeAttribute() {}})
  const message = {textContent: ""}
  const doc = new EventTarget()
  doc.hidden = false
  const previousDocument = globalThis.document
  globalThis.document = doc
  const samples = []
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}}, dataset: {kind: "podcast", session: "abc", position: "42", ...STRINGS},
    querySelector: selector => ({audio, "[data-player-message]": message}[selector])}),
    pushEvent: (_event, sample, reply) => {samples.push(sample); reply({saved: true})}}
  try {
    hook.mounted()
    assert.equal(audio.currentTime, 0)
    // A chapter chosen before the audio knows itself is where it starts, not the saved place.
    hook.el.dispatchEvent(new CustomEvent("sikio:seek", {detail: {position: 33}}))
    audio.readyState = 1
    audio.dispatchEvent(new Event("loadedmetadata"))
    assert.equal(audio.currentTime, 33)
    assert.equal(message.textContent, "", "a player that works says nothing")
    hook.el.dispatchEvent(new CustomEvent("sikio:seek", {detail: {position: 70}}))
    assert.equal(audio.currentTime, 70, "a chapter moves the audio")
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
  let events, poll, position = 0, destroyed = false, sought = null, playerReady = false, muted = false
  let state = 2
  const calls = []
  globalThis.document = doc
  globalThis.window = {YT: {PlayerState: {PLAYING: 1, PAUSED: 2, BUFFERING: 3, ENDED: 0}, Player: class {
    constructor(_frame, options) {events = options.events}
    getCurrentTime() {return position}
    getDuration() {return 100}
    getPlayerState() {return state}
    pauseVideo() {calls.push("pauseVideo")}
    // Like YouTube's own, the player answers only once it said it is ready.
    seekTo(at) {if (playerReady) sought = at}
    playVideo() {calls.push("playVideo")}
    mute() {muted = true}
    unMute() {muted = false}
    isMuted() {return muted}
    destroy() {destroyed = true}
  }}}
  globalThis.setInterval = callback => {poll = callback; return 0}
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}}, dataset: {kind: "youtube", session: "video", position: "0", ...STRINGS},
    querySelector: selector => selector === "[data-player-message]" ? message : selector === "iframe" ? {} : null}),
    pushEvent: (_event, sample, reply) => {samples.push(sample); reply({saved: true})}}
  try {
    hook.mounted()
    await Promise.resolve()
    // A chapter chosen before the player is ready is not lost.
    hook.el.dispatchEvent(new CustomEvent("sikio:seek", {detail: {position: 21}}))
    playerReady = true
    events.onReady()
    assert.equal(sought, 21)
    assert.equal(message.textContent, "", "a player that works says nothing")
    hook.el.dispatchEvent(new CustomEvent("sikio:seek", {detail: {position: 55}}))
    assert.equal(sought, 55, "a chapter moves the video")
    // The page's keys drive the video through the API. The fake reports paused.
    const command = detail => hook.el.dispatchEvent(new CustomEvent("sikio:command", {detail}))
    command({name: "toggle"})
    assert.deepEqual(calls, ["playVideo"])
    // A video that buffers after a skip is meant to play, so the key pauses it.
    state = 3
    command({name: "toggle"})
    assert.deepEqual(calls, ["playVideo", "pauseVideo"])
    state = 2
    position = 40
    command({name: "skip", by: 30})
    assert.equal(sought, 70)
    command({name: "mute"})
    assert.equal(muted, true)
    command({name: "mute"})
    assert.equal(muted, false)
    poll()
    position = 30
    poll()
    assert.equal(samples.at(-1)?.position, 30)
    // Playing is saved every few seconds, a jump at once: the page shows the chapter it reached.
    state = 1
    position = 31
    poll()
    assert.equal(samples.at(-1).position, 30)
    position = 90
    poll()
    assert.equal(samples.at(-1).position, 90)
    state = 2
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

// A browser may refuse to start sound on its own. Then the reader needs to know what to press.
test("audio the browser refuses to start asks for the play button", async () => {
  const audio = new EventTarget()
  Object.assign(audio, {dataset: {}, currentTime: 0, duration: 100, readyState: 1, playbackRate: 1,
    play: () => Promise.reject(new Error("NotAllowedError")), pause() {}, load() {}, removeAttribute() {}})
  const message = {textContent: ""}
  const previousDocument = globalThis.document
  globalThis.document = Object.assign(new EventTarget(), {hidden: false})
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}}, dataset: {kind: "podcast", session: "abc", position: "0", ...STRINGS},
    querySelector: selector => ({audio, "[data-player-message]": message}[selector])}),
    pushEvent: () => {}}
  try {
    hook.mounted()
    await new Promise(resolve => setImmediate(resolve))
    assert.equal(message.textContent, STRINGS.readyAudioManual)
  } finally {
    hook.destroyed()
    globalThis.document = previousDocument
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
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}}, dataset: {kind: "peertube", session: "v", position: "42", ...STRINGS},
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

    assert.ok(said.every(text => text === ""), "a player that works says nothing")
    assert.equal(samples.at(-1)?.position, 42.5)
    assert.equal(samples.at(-1)?.duration, 100)

    // Playing is saved every few seconds, a jump at once: the page shows the chapter it reached.
    const playing = position => fromEmbed({method: "peertube::playbackStatusUpdate",
      params: {position, duration: 100, playbackState: "playing"}})
    playing(43)
    playing(80)
    assert.deepEqual(samples.map(sample => sample.position), [42.5, 80])

    fromEmbed({method: "peertube::playbackStatusChange", params: "ended"})
    await Promise.resolve()
    assert.equal(samples.at(-1).ended, true)

    // A chapter moves the instance's player.
    hook.el.dispatchEvent(new CustomEvent("sikio:seek", {detail: {position: 118}}))
    assert.ok(posted.some(m => m.method === "peertube::seek" && m.params === 118), "the instance seeks")
    // The page's keys drive the instance's player. It said last that it ended, so play.
    const command = detail => hook.el.dispatchEvent(new CustomEvent("sikio:command", {detail}))
    command({name: "toggle"})
    assert.ok(posted.some(m => m.method === "peertube::play"), "toggle plays what is not playing")
    command({name: "skip", by: -15})
    assert.ok(posted.some(m => m.method === "peertube::seek" && m.params === 65), "a skip from the reported place")
    command({name: "mute"})
    assert.ok(posted.some(m => m.method === "peertube::setVolume" && m.params === 0), "sound off")

    // Closing flushes first, while the frame is still in the page, and that is what pauses it.
    hook.el.dispatchEvent(new CustomEvent("sikio:flush", {detail: {done: () => {}}}))
    assert.ok(posted.some(m => m.method === "peertube::pause"), "closing stops the instance's player")
    hook.destroyed()
  } finally {
    hook.destroyed()
    globalThis.document = previous.document
    globalThis.window = previous.window
  }
})

// LiveView removes the player's element before it calls destroyed, so the iframe is detached and
// has no window to write to. Cleaning up must not throw: an exception there aborts LiveView's patch
// before the dock's reply arrives, and from then on no button works.
test("a PeerTube player whose frame is gone cleans up quietly and hears nothing more", () => {
  const previous = {document: globalThis.document, window: globalThis.window}
  const samples = []
  globalThis.document = new EventTarget()
  globalThis.window = new EventTarget()

  const iframe = {src: "https://video.example.org/videos/embed/abc?api=1", contentWindow: {postMessage: () => {}}}
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}}, dataset: {kind: "peertube", session: "v", position: "0", ...STRINGS},
    querySelector: selector => selector === "[data-player-message]" ? {textContent: ""} : selector === "iframe" ? iframe : null}),
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
    fromEmbed({method: "peertube::playbackStatusUpdate", params: {position: 5, duration: 36, playbackState: "playing"}})
    iframe.contentWindow = null
    assert.doesNotThrow(() => hook.destroyed())
    const count = samples.length
    fromEmbed({method: "peertube::playbackStatusChange", params: "paused"})
    assert.equal(samples.length, count, "a destroyed player saves nothing for another embed")
  } finally {
    globalThis.document = previous.document
    globalThis.window = previous.window
  }
})

// A paused embed keeps reporting the same place twice a second. Only becoming paused is news.
test("a paused PeerTube video saves its place once, not with every report", async () => {
  const previous = {document: globalThis.document, window: globalThis.window}
  const samples = []
  globalThis.document = new EventTarget()
  globalThis.window = new EventTarget()

  const iframe = {src: "https://video.example.org/videos/embed/abc?api=1", contentWindow: {postMessage: () => {}}}
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}}, dataset: {kind: "peertube", session: "v", position: "0", ...STRINGS},
    querySelector: selector => selector === "[data-player-message]" ? {textContent: ""} : selector === "iframe" ? iframe : null}),
    pushEvent: (_event, sample, reply) => {samples.push(sample); reply({saved: true})}}

  const report = (state, position = 12) => {
    const event = new Event("message")
    event.data = JSON.stringify({method: "peertube::playbackStatusUpdate", params: {position, duration: 36, playbackState: state}})
    event.origin = "https://video.example.org"
    window.dispatchEvent(event)
  }

  try {
    hook.mounted()
    const ready = new Event("message")
    ready.data = JSON.stringify({method: "peertube::__ready", params: {type: "publish-request", publish: []}})
    ready.origin = "https://video.example.org"
    window.dispatchEvent(ready)
    report("playing")
    const playing = samples.length
    for (let n = 0; n < 4; n++) report("paused")
    assert.equal(samples.length, playing + 1)
    // A seek while paused moves the place, and that is saved at once.
    report("paused", 300)
    report("paused", 300)
    assert.equal(samples.length, playing + 2)
    assert.equal(samples.at(-1).position, 300)
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
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}}, dataset: {kind: "peertube", session: "v", position: "0", ...STRINGS},
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

// The capsule shows play or pause and a line for how far it has come. The player says both on its
// element, whichever kind it is.
test("the player says whether it plays and how far it has come", async () => {
  const previous = {document: globalThis.document, window: globalThis.window}
  globalThis.document = Object.assign(new EventTarget(), {hidden: false})
  globalThis.window = new EventTarget()
  const element = (dataset, querySelector) => {
    const props = {}
    return Object.assign(new EventTarget(), {dataset: {...dataset, ...STRINGS}, querySelector, props,
      style: {setProperty: (name, value) => { props[name] = value }}})
  }

  const audio = new EventTarget()
  Object.assign(audio, {dataset: {}, currentTime: 0, duration: 100, readyState: 0, playbackRate: 1,
    paused: true, play() { return Promise.resolve() }, pause() {}, load() {}, removeAttribute() {}})
  const message = {textContent: ""}
  const sound = {...MediaPlayer,
    el: element({kind: "podcast", session: "a", position: "0"},
      selector => ({audio, "[data-player-message]": message}[selector])),
    pushEvent: (_event, _sample, reply) => reply({saved: true})}

  const iframe = {src: "https://video.example.org/videos/embed/abc", contentWindow: {postMessage() {}}}
  const video = {...MediaPlayer,
    el: element({kind: "peertube", session: "v", position: "0"},
      selector => selector === "iframe" ? iframe : selector === "[data-player-message]" ? message : null),
    pushEvent: (_event, _sample, reply) => reply({saved: true})}

  try {
    sound.mounted()
    audio.dispatchEvent(new Event("play"))
    assert.equal(sound.el.dataset.playing, "true")
    audio.currentTime = 25
    audio.dispatchEvent(new Event("timeupdate"))
    assert.equal(sound.el.props["--played"], "0.25")
    audio.dispatchEvent(new Event("pause"))
    assert.equal(sound.el.dataset.playing, "false")

    video.mounted()
    const status = (position, playbackState) => {
      const event = new Event("message")
      event.data = JSON.stringify({method: "peertube::playbackStatusUpdate",
        params: {position, duration: 100, playbackState}})
      event.origin = "https://video.example.org"
      window.dispatchEvent(event)
    }
    status(50, "playing")
    assert.equal(video.el.dataset.playing, "true")
    assert.equal(video.el.props["--played"], "0.5")
    status(50, "paused")
    assert.equal(video.el.dataset.playing, "false")
  } finally {
    sound.destroyed()
    video.destroyed()
    globalThis.document = previous.document
    globalThis.window = previous.window
  }
})

// The system's own controls for an episode: the lock screen, the control centre, headphones and
// media keys. A stand-in session records what the player tells it.
function mediaSession() {
  const session = {metadata: null, playbackState: "none", handlers: {}, position: null,
    setActionHandler(name, handler) {
      if (handler) this.handlers[name] = handler
      else delete this.handlers[name]
    },
    setPositionState(state) { this.position = state }}
  const previous = Object.getOwnPropertyDescriptor(globalThis, "navigator")
  Object.defineProperty(globalThis, "navigator", {value: {mediaSession: session}, configurable: true})
  globalThis.MediaMetadata = class { constructor(init) { Object.assign(this, init) } }
  return {session, restore: () => {
    Object.defineProperty(globalThis, "navigator", previous)
    delete globalThis.MediaMetadata
  }}
}

function episode(dataset) {
  const calls = []
  const audio = new EventTarget()
  Object.assign(audio, {dataset: {}, currentTime: 0, duration: 400, readyState: 0, playbackRate: 1,
    paused: true, muted: false,
    play() { calls.push("play"); this.paused = false; return Promise.resolve() },
    pause() { calls.push("pause"); this.paused = true }, load() {}, removeAttribute() {}})
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}},
    dataset: {kind: "podcast", session: dataset.session, position: "0", ...dataset, ...STRINGS},
    querySelector: selector => ({audio, "[data-player-message]": {textContent: ""}}[selector])}),
    pushEvent: (_event, _sample, reply) => reply({saved: true})}
  return {hook, audio, calls}
}

test("the system's controls show the episode and drive it", () => {
  const {session, restore} = mediaSession()
  const previousDocument = globalThis.document
  globalThis.document = Object.assign(new EventTarget(), {hidden: false})
  const {hook, audio, calls} = episode({session: "a", title: "One & two", source: "Small Hours",
    artwork: "/pictures/abc"})
  try {
    hook.mounted()
    assert.equal(session.metadata.title, "One & two")
    assert.equal(session.metadata.artist, "Small Hours")
    assert.deepEqual(session.metadata.artwork, [{src: "/pictures/abc"}])

    audio.readyState = 1
    audio.dispatchEvent(new Event("loadedmetadata"))
    session.handlers.pause()
    session.handlers.play()
    assert.deepEqual(calls, ["play", "pause", "play"], "pause and play do what they say")
    session.handlers.play()
    assert.equal(calls.length, 3, "play while playing changes nothing")

    audio.currentTime = 100
    session.handlers.seekbackward({})
    assert.equal(audio.currentTime, 85)
    session.handlers.seekforward({})
    assert.equal(audio.currentTime, 115)
    // iOS draws its skip buttons with an offset of its own and sends it along; the jump follows.
    session.handlers.seekbackward({seekOffset: 10})
    assert.equal(audio.currentTime, 105)
    session.handlers.seekforward({seekOffset: 10})
    assert.equal(audio.currentTime, 115)
    session.handlers.seekto({seekTime: 300})
    assert.equal(audio.currentTime, 300)

    audio.dispatchEvent(new Event("play"))
    assert.equal(session.playbackState, "playing")
    audio.dispatchEvent(new Event("timeupdate"))
    assert.deepEqual(session.position, {duration: 400, position: 300, playbackRate: 1})
    audio.dispatchEvent(new Event("pause"))
    assert.equal(session.playbackState, "paused")

    hook.destroyed()
    assert.equal(session.metadata, null)
    assert.deepEqual(session.handlers, {})
    assert.equal(session.playbackState, "none")
  } finally {
    hook.destroyed()
    globalThis.document = previousDocument
    restore()
  }
})

// The next episode may announce itself before the last one's player is gone.
test("a player clears only what it set itself", () => {
  const {session, restore} = mediaSession()
  const previousDocument = globalThis.document
  globalThis.document = Object.assign(new EventTarget(), {hidden: false})
  const first = episode({session: "a", title: "First", source: "Small Hours"})
  const second = episode({session: "b", title: "Second", source: "Small Hours"})
  try {
    first.hook.mounted()
    second.hook.mounted()
    first.hook.destroyed()
    assert.equal(session.metadata.title, "Second")
    assert.ok(session.handlers.play, "the next player keeps its controls")
  } finally {
    first.hook.destroyed()
    second.hook.destroyed()
    globalThis.document = previousDocument
    restore()
  }
})

// The dock plays on with the queue when an item ends; the player says so.
test("an ended episode tells the page", () => {
  const previous = {document: globalThis.document, window: globalThis.window}
  globalThis.document = Object.assign(new EventTarget(), {hidden: false})
  globalThis.window = new EventTarget()
  const ended = []
  window.addEventListener("sikio:ended", () => ended.push(true))
  const {hook, audio} = episode({session: "e", title: "E", source: "S"})
  try {
    hook.mounted()
    audio.readyState = 1
    audio.dispatchEvent(new Event("loadedmetadata"))
    audio.currentTime = 400
    audio.dispatchEvent(new Event("ended"))
    assert.deepEqual(ended, [true])
  } finally {
    hook.destroyed()
    globalThis.document = previous.document
    globalThis.window = previous.window
  }
})
