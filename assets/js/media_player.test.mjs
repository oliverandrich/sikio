// SPDX-License-Identifier: AGPL-3.0-or-later

import {test} from "node:test"
import assert from "node:assert/strict"
import {createReporter, MediaPlayer, playsHls, recreated} from "./media_player.mjs"

// Messages the server renders into the element's dataset.
// The tests assert on them, because users read them when playback stops.
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
  videoFailed: "This video could not be loaded."
}

// The hook replaces a rendered video with one it creates. A fake creates itself, so its
// assertions follow the element the hook plays.
const inPlace = media => Object.assign(media, {attributes: [], ownerDocument: {createElement: () => media},
  replaceWith() { media.recreated = true }})

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

// The player's own hints, such as "Press play" after a blocked autoplay, stay after a save.
// A save clears only warnings the reporter set itself.
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

// A paused PeerTube embed reports twice a second, and each report requests a save.
// Finishing must not wait for an empty save queue. It would never end, and no button would work.
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

// Player commands control the audio: play/pause, skips, chapters and mute.
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
    dataset: {kind: "podcast", session: "abc", position: "0", chapters: JSON.stringify([{at: 0, title: "A"}, {at: 118, title: "B"}, {at: 291, title: "C"}]), ...STRINGS},
    querySelector: selector => ({audio, "[data-player-message]": {textContent: ""}}[selector])}),
    pushEvent: (_event, _sample, reply) => reply({saved: true})}
  const command = detail => hook.el.dispatchEvent(new CustomEvent("sikio:command", {detail}))
  try {
    hook.mounted()
    audio.readyState = 1
    audio.dispatchEvent(new Event("loadedmetadata"))
    // Restoring the position starts playback, so the first toggle pauses and the second plays.
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
    // Chapters can change later, from a chapters file or a measured duration.
    hook.el.dataset.chapters = JSON.stringify([{at: 0, title: "A"}, {at: 50, title: "B"}])
    audio.currentTime = 10
    command({name: "chapter", direction: 1})
    assert.equal(audio.currentTime, 50, "the chapters the page names now")
  } finally {
    hook.destroyed()
    globalThis.document = previousDocument
  }
})

// A skip before metadata loads moves from the saved position, not from zero.
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
    // A chapter selected before metadata loads sets the start instead of the saved position.
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
  const calls = [], unloaded = []
  globalThis.document = doc
  globalThis.window = {YT: {PlayerState: {PLAYING: 1, PAUSED: 2, BUFFERING: 3, ENDED: 0}, Player: class {
    constructor(_frame, options) {events = options.events}
    getCurrentTime() {return position}
    getDuration() {return 100}
    getPlayerState() {return state}
    pauseVideo() {calls.push("pauseVideo")}
    // Like the real API, the fake ignores `seekTo` until the player is ready.
    seekTo(at) {if (playerReady) sought = at}
    playVideo() {calls.push("playVideo")}
    mute() {muted = true}
    unMute() {muted = false}
    isMuted() {return muted}
    unloadModule(name) {unloaded.push(name)}
    destroy() {destroyed = true}
  }}}
  globalThis.setInterval = callback => {poll = callback; return 0}
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}}, dataset: {kind: "youtube", session: "video", position: "0", ...STRINGS},
    querySelector: selector => selector === "[data-player-message]" ? message : selector === "iframe" ? {} : null}),
    pushEvent: (_event, sample, reply) => {samples.push(sample); reply({saved: true})}}
  try {
    hook.mounted()
    await Promise.resolve()
    // A chapter selected before the player is ready is applied on ready.
    hook.el.dispatchEvent(new CustomEvent("sikio:seek", {detail: {position: 21}}))
    playerReady = true
    events.onReady()
    assert.equal(sought, 21)
    // YouTube enables captions for some videos by default. The player unloads them at start.
    // Its CC button turns them back on.
    assert.deepEqual(unloaded, ["captions"])
    assert.equal(message.textContent, "", "a player that works says nothing")
    hook.el.dispatchEvent(new CustomEvent("sikio:seek", {detail: {position: 55}}))
    assert.equal(sought, 55, "a chapter moves the video")
    // Player commands control the video through the API. The fake reports paused.
    const command = detail => hook.el.dispatchEvent(new CustomEvent("sikio:command", {detail}))
    command({name: "toggle"})
    assert.deepEqual(calls, ["playVideo"])
    // A video buffering after a skip is meant to play, so toggle pauses it.
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
    // During playback a save happens every few seconds, a jump saves at once.
    // So the page shows the chapter reached by the jump.
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

// A browser may block autoplay with sound. The player then asks the user to press play.
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

// A PeerTube embed reports its position about twice a second. Each report is a sample.
// The first report also shows that the player exists. Before it, a query returns zero.
// Saving that zero would overwrite the saved position.
// A PeerTube video plays in a video element. The audio element's code drives it.
test("a PeerTube video plays in its own element with the audio's controls", () => {
  const previousDocument = globalThis.document, previousFetch = globalThis.fetch
  globalThis.document = Object.assign(new EventTarget(), {hidden: false})
  const reports = []
  globalThis.fetch = (url, options) => { reports.push({url, ...options}); return Promise.resolve() }
  const video = inPlace(new EventTarget())
  Object.assign(video, {dataset: {}, currentTime: 0, duration: 600, readyState: 0, playbackRate: 1,
    paused: true, muted: false, play() { this.paused = false; return Promise.resolve() },
    pause() { this.paused = true }, load() {}, removeAttribute() {}})
  const message = {textContent: ""}, samples = []
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}},
    dataset: {kind: "peertube", session: "v", position: "120", views: "https://video.example.org/api/v1/videos/abc/views", ...STRINGS},
    querySelector: selector => ({video, "[data-player-message]": message}[selector])}),
    pushEvent: (_event, sample, reply) => {samples.push(sample); reply({saved: true})}}
  try {
    hook.mounted()
    assert.equal(video.recreated, true, "Safari paints a video the hook created")
    video.readyState = 1
    video.dispatchEvent(new Event("loadedmetadata"))
    assert.equal(video.currentTime, 120, "the saved place")
    assert.equal(video.paused, false)
    // A playing video tells its instance that someone watches.
    video.dispatchEvent(new Event("timeupdate"))
    assert.equal(reports.length, 1)
    assert.equal(reports[0].url, "https://video.example.org/api/v1/videos/abc/views")
    assert.equal(reports[0].credentials, "omit")
    assert.deepEqual(JSON.parse(reports[0].body).currentTime, 120)
    hook.el.dispatchEvent(new CustomEvent("sikio:command", {detail: {name: "skip", by: 30}}))
    assert.equal(video.currentTime, 150)
    video.dispatchEvent(new Event("pause"))
    assert.equal(samples.at(-1).position, 150)
    video.dispatchEvent(new Event("error"))
    assert.equal(message.textContent, STRINGS.videoFailed)
    hook.destroyed()
    assert.equal(video.paused, true)
  } finally {
    hook.destroyed()
    globalThis.document = previousDocument
    globalThis.fetch = previousFetch
  }
})

// Safari leaves a video blank that LiveView inserted. The hook plays a copy it creates itself.
test("a rendered video is replaced by a created copy with its attributes", () => {
  const created = {attributes: {}, setAttribute(name, value) { this.attributes[name] = value }}
  const rendered = {attributes: [{name: "data-src", value: "https://video.example.org/master.m3u8"},
    {name: "playsinline", value: ""}], ownerDocument: {createElement: tag => tag === "video" && created},
    replaceWith(next) { this.replacement = next }}
  assert.equal(recreated(rendered), created)
  assert.equal(rendered.replacement, created)
  assert.deepEqual(created.attributes, {"data-src": "https://video.example.org/master.m3u8", playsinline: ""})
})

// Chromium answers "maybe" for HLS but cannot play it. Only Apple's WebKit plays it itself.
test("only Safari plays an HLS playlist itself", () => {
  const video = answer => ({canPlayType: () => answer})
  assert.equal(playsHls(video("maybe"), "Apple Computer, Inc."), true)
  assert.equal(playsHls(video("maybe"), "Google Inc."), false)
  assert.equal(playsHls(video(""), "Apple Computer, Inc."), false)
})

// Other browsers load the vendored hls.js once, on the first playlist, and play through it.
// It stays at or below 1080p. A web file plays as it is.
test("a playlist plays through hls.js, capped at 1080p, and a file plays as it is", async () => {
  const previous = {document: globalThis.document, Hls: globalThis.Hls}
  const scripts = []
  globalThis.document = Object.assign(new EventTarget(), {hidden: false,
    createElement: () => ({}), head: {append: script => scripts.push(script)}})
  const players = []
  class FakeHls {
    static isSupported() { return true }
    static Events = {MANIFEST_PARSED: "manifest", ERROR: "error"}
    constructor(config) { this.config = config; this.handlers = {}; players.push(this) }
    on(event, handler) { this.handlers[event] = handler }
    loadSource(url) { this.source = url }
    attachMedia(media) { this.media = media }
    destroy() { this.destroyed = true }
  }
  const video = (src) => Object.assign(inPlace(new EventTarget()), {dataset: {src}, currentTime: 0,
    duration: 600, readyState: 0, playbackRate: 1, paused: true, canPlayType: () => "maybe",
    play() { return Promise.resolve() }, pause() {}, load() {}, removeAttribute() {}})
  const hookFor = media => ({...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}},
    dataset: {kind: "peertube", session: "v", position: "0", hls: "/vendor/hls.js/hls.min.js", ...STRINGS},
    querySelector: selector => ({video: media, "[data-player-message]": message}[selector])}),
    pushEvent: (_event, _sample, reply) => reply({saved: true})})
  const message = {textContent: ""}
  const stream = video("https://video.example.org/master.m3u8"), file = video("https://video.example.org/v.mp4")
  const streaming = hookFor(stream), filing = hookFor(file)
  try {
    streaming.mounted()
    assert.equal(scripts.length, 1)
    assert.equal(scripts[0].src, "/vendor/hls.js/hls.min.js")
    globalThis.Hls = FakeHls
    scripts[0].onload()
    await new Promise(resolve => setTimeout(resolve, 0))
    const [player] = players
    assert.equal(player.source, "https://video.example.org/master.m3u8")
    assert.equal(player.media, stream)
    player.handlers.manifest("manifest", {levels: [{height: 360}, {height: 720}, {height: 1080}, {height: 2160}]})
    assert.equal(player.autoLevelCapping, 2)
    player.handlers.error("error", {fatal: true})
    assert.equal(message.textContent, STRINGS.videoFailed)

    filing.mounted()
    assert.equal(file.src, "https://video.example.org/v.mp4")
    assert.equal(scripts.length, 1, "a file needs no hls.js")

    streaming.destroyed()
    assert.equal(player.destroyed, true)
  } finally {
    streaming.destroyed()
    filing.destroyed()
    globalThis.document = previous.document
    globalThis.Hls = previous.Hls
  }
})

// The switch plays the audio-only file in an audio element, which iOS keeps playing in the
// background. It continues at the same place and speed, and the picture comes back the same way.
test("a PeerTube video switches to its sound alone and back at the same place", () => {
  const fake = () => {
    const media = new EventTarget()
    return Object.assign(media, {dataset: {}, currentTime: 0, duration: 600, readyState: 0,
      playbackRate: 1, paused: true, muted: false, hidden: false,
      play() { this.paused = false; return Promise.resolve() }, pause() { this.paused = true },
      load() {}, removeAttribute(name) { if (name === "src") this.src = "" },
      remove() { this.removed = true }, after(next) { this.next = next }})
  }
  const video = inPlace(fake()), audio = fake(), samples = []
  const previousDocument = globalThis.document
  globalThis.document = Object.assign(new EventTarget(), {hidden: false, createElement: () => audio})
  const button = Object.assign(new EventTarget(), {attributes: {},
    setAttribute(name, value) { this.attributes[name] = value }})
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}},
    dataset: {kind: "peertube", session: "v", position: "0", audioSrc: "https://video.example.org/a.mp4", ...STRINGS},
    querySelector: selector => ({video, "[data-audio-only]": button, "[data-player-message]": {textContent: ""}}[selector])}),
    pushEvent: (_event, sample, reply) => {samples.push(sample); reply({saved: true})}}
  try {
    hook.mounted()
    video.readyState = 1
    video.dispatchEvent(new Event("loadedmetadata"))
    video.currentTime = 200
    video.playbackRate = 1.5
    let fullscreen = false
    video.requestFullscreen = () => { fullscreen = true }
    hook.el.dispatchEvent(new CustomEvent("sikio:command", {detail: {name: "fullscreen"}}))
    assert.equal(fullscreen, true, "the video fills the screen")
    fullscreen = false

    button.dispatchEvent(new Event("click"))
    assert.equal(video.paused, true)
    assert.equal(video.hidden, true)
    assert.equal(video.next, audio, "the audio element follows the video")
    assert.equal(audio.src, "https://video.example.org/a.mp4")
    assert.equal(button.attributes["aria-pressed"], "true")
    hook.el.dispatchEvent(new CustomEvent("sikio:command", {detail: {name: "fullscreen"}}))
    assert.equal(fullscreen, false, "the hidden video stays out of fullscreen")
    audio.readyState = 1
    audio.dispatchEvent(new Event("loadedmetadata"))
    assert.equal(audio.currentTime, 200)
    assert.equal(audio.playbackRate, 1.5)
    assert.equal(audio.paused, false, "a playing video goes on playing as sound")
    audio.currentTime = 260
    audio.pause()
    audio.dispatchEvent(new Event("pause"))
    assert.equal(samples.at(-1).position, 260, "the audio element now reports the place")
    video.dispatchEvent(new Event("pause"))
    assert.equal(samples.at(-1).position, 260, "the hidden video reports nothing")

    button.dispatchEvent(new Event("click"))
    assert.equal(audio.removed, true)
    assert.equal(video.hidden, false)
    assert.equal(video.currentTime, 260)
    assert.equal(video.paused, true, "a paused sound stays paused as video")
    assert.equal(button.attributes["aria-pressed"], "false")
  } finally {
    hook.destroyed()
    globalThis.document = previousDocument
  }
})

// Before the video loads it has no place of its own. The sound starts at the saved place.
test("a switch to the sound before the video loads keeps the saved place", () => {
  const fake = () => Object.assign(new EventTarget(), {dataset: {}, currentTime: 0, duration: 3600,
    readyState: 0, playbackRate: 1, paused: true, hidden: false,
    play() { this.paused = false; return Promise.resolve() }, pause() { this.paused = true },
    load() {}, removeAttribute() {}, remove() {}, after() {}})
  const video = inPlace(fake()), audio = fake()
  const previousDocument = globalThis.document
  globalThis.document = Object.assign(new EventTarget(), {hidden: false, createElement: () => audio})
  const button = Object.assign(new EventTarget(), {setAttribute() {}})
  const hook = {...MediaPlayer, el: Object.assign(new EventTarget(), {style: {setProperty() {}},
    dataset: {kind: "peertube", session: "v", position: "1800", audioSrc: "https://video.example.org/a.mp4", ...STRINGS},
    querySelector: selector => ({video, "[data-audio-only]": button, "[data-player-message]": {textContent: ""}}[selector])}),
    pushEvent: (_event, _sample, reply) => reply({saved: true})}
  try {
    hook.mounted()
    button.dispatchEvent(new Event("click"))
    audio.readyState = 1
    audio.dispatchEvent(new Event("loadedmetadata"))
    assert.equal(audio.currentTime, 1800)
    assert.equal(audio.paused, false, "the start the user asked for goes on")
  } finally {
    hook.destroyed()
    globalThis.document = previousDocument
  }
})

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


  try {
    sound.mounted()
    audio.dispatchEvent(new Event("play"))
    assert.equal(sound.el.dataset.playing, "true")
    audio.currentTime = 25
    audio.dispatchEvent(new Event("timeupdate"))
    assert.equal(sound.el.props["--played"], "0.25")
    audio.dispatchEvent(new Event("pause"))
    assert.equal(sound.el.dataset.playing, "false")
  } finally {
    sound.destroyed()
    globalThis.document = previous.document
    globalThis.window = previous.window
  }
})

// The Media Session API backs lock screen, control centre, headphone and media key controls.
// The fake session records what the player sets.
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
    // iOS sends its own `seekOffset` for its skip buttons, and the jump uses it.
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

// The next episode's player can mount before the previous one is destroyed.
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

// The player dispatches `sikio:ended` on window when an episode ends. The dock then plays on.
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

// The dock's face is rendered once. `updated` draws chapters loaded later on its bar.
// The same chapters are not drawn twice.
test("chapters learned later are drawn on the dock's bar", () => {
  const previousDocument = globalThis.document
  globalThis.document = {createElement: () => ({dataset: {}, style: {setProperty() {}}, setAttribute() {}})}
  const bar = {appended: [], append(...els) { this.appended.push(...els) }}
  const face = {querySelector: s => s === "[data-audio-bar]" ? bar : null, querySelectorAll: () => []}
  const hook = {...MediaPlayer, media: {duration: 360},
    el: {dataset: {chapters: JSON.stringify([{at: 0, title: "A"}, {at: 90, title: "B"}])},
      querySelector: s => s === "[data-audio-face]" ? face : null}}
  try {
    hook.updated()
    assert.deepEqual(bar.appended.map(mark => mark.dataset.title), ["A", "B"])
    hook.updated()
    assert.equal(bar.appended.length, 2, "the same chapters are drawn once")
  } finally {
    globalThis.document = previousDocument
  }
})
