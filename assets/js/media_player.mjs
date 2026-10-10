// SPDX-License-Identifier: AGPL-3.0-or-later

import {bindFace, feedLength, renderMarks} from "./audio_face.mjs"
import {createViews, postView} from "./peertube_views.mjs"

// Sends at most one save at a time.
// While one is in flight, a newer sample replaces the pending one.
export function createReporter({session, read, send, stop, message, strings, now = Date.now}) {
  let sequence = 0, inFlight = null, pending = null, lastSave = -Infinity
  let connected = true, closed = false, completed = false
  let finishDone = null, finishing = false, warned = false
  const warn = text => { warned = true; message(text) }

  function finishResult(saved) {
    const done = finishDone
    finishDone = null
    finishing = false
    done?.(saved)
  }

  function flush() {
    if (closed || !connected || inFlight !== null || !pending) return
    const sample = {...pending, session, sequence: ++sequence}
    pending = null
    inFlight = sample.sequence
    send(sample, reply => {
      if (closed || inFlight !== sample.sequence) return
      inFlight = null
      if (!reply.saved) {
        closed = true
        stop()
        warn(strings.stale)
        finishResult(false)
        return
      }
      // A successful save shows no message. It clears the message only after a warning from `warn`.
      if (warned) { warned = false; message("") }
      flush()
      if (inFlight === null && !pending) finishResult(true)
    })
  }

  return {
    save(ended = false, force = false) {
      // During `finish`, the final position is already pending or in flight.
      // A player may keep reporting while paused.
      // Accepting those reports would refill the queue, and `finish` would never complete.
      if (closed || finishing || (!force && now() - lastSave < 5000)) return
      const current = read()
      if (!current || !Number.isFinite(current.position) || current.position < 0) return
      lastSave = now()
      completed ||= ended
      pending = {position: current.position,
        duration: Number.isFinite(current.duration) && current.duration > 0 ? current.duration : null,
        ended: completed}
      flush()
    },
    disconnect() {
      connected = false
      inFlight = null
      stop()
      warn(strings.disconnected)
      finishResult(false)
    },
    reconnect() {
      connected = true
      this.save(false, true)
      flush()
    },
    finish(done) {
      if (closed) return done(true)
      stop()
      if (!connected) {
        warn(strings.reconnectFirst)
        return done(false)
      }
      finishDone = done
      this.save(false, true)
      finishing = true
      if (inFlight === null && !pending) finishResult(true)
    },
    destroy() { closed = true; pending = null; finishResult(false) }
  }
}

// YouTube positions arrive once per second.
// A change of more than 3 seconds between two readings is a seek.
// The seek can come from a key, a chapter or the embed's controls.
// Audio and video elements use their `seeked` event instead.
export function jumped(previous, position) {
  return Math.abs(position - previous) > 3
}

// Target of a chapter key. Forward: the next chapter start more than 1 second ahead.
// Backward: the current chapter's start, or the previous chapter's within 3 seconds of a start.
export function chapterTarget(starts, position, direction) {
  if (direction > 0) return starts.find(start => start > position + 1) ?? null
  const before = starts.filter(start => start <= position)
  if (before.length === 0) return 0
  const current = before[before.length - 1]
  return position - current < 3 ? (before[before.length - 2] ?? 0) : current
}

let youtubeAPI
function loadYouTube(unavailable) {
  if (window.YT?.Player) return Promise.resolve(window.YT)
  if (youtubeAPI) return youtubeAPI
  youtubeAPI = new Promise((resolve, reject) => {
    const script = document.createElement("script")
    const timeout = setTimeout(() => fail(), 15000)
    const fail = () => {
      clearTimeout(timeout)
      script.remove()
      youtubeAPI = null
      reject(new Error(unavailable))
    }
    window.onYouTubeIframeAPIReady = () => {clearTimeout(timeout); resolve(window.YT)}
    script.src = "https://www.youtube.com/iframe_api"
    script.referrerPolicy = "strict-origin-when-cross-origin"
    script.onerror = fail
    document.head.appendChild(script)
  })
  return youtubeAPI
}

// Whether the browser plays an HLS playlist itself. Safari does, on macOS and iOS, and keeps
// background playback, AirPlay and Picture in Picture. Chromium answers "maybe" but cannot play
// it, so only Apple's WebKit counts.
export function playsHls(video, vendor = globalThis.navigator?.vendor) {
  return Boolean(vendor?.startsWith("Apple") && video.canPlayType("application/vnd.apple.mpegurl"))
}

// Loads the vendored hls.js once, as a script tag, on the first playlist.
let hlsScript
function loadHls(src) {
  if (globalThis.Hls) return Promise.resolve(globalThis.Hls)
  hlsScript ??= new Promise((resolve, reject) => {
    const script = document.createElement("script")
    script.src = src
    script.onload = () => resolve(globalThis.Hls)
    script.onerror = () => { hlsScript = null; script.remove?.(); reject(new Error("hls.js")) }
    document.head.append(script)
  })
  return hlsScript
}

// The hook instance that last set the Media Session.
// Cleanup of other instances leaves it unchanged.
let owner = null

// Parses the current `data-chapters`: each chapter's start (`at`) and title.
const chapters = el => JSON.parse(el.dataset.chapters || "[]")

const systemSession = () => globalThis.navigator?.mediaSession

const offset = (given, fallback) => (given > 0 ? given : fallback)

// `setActionHandler` throws for an unsupported action. The other actions still register.
function handle(session, action, handler) {
  try { session.setActionHandler(action, handler) } catch { /* unsupported action */ }
}

// Safari does not paint a video element that a LiveView patch inserted.
// Through hls.js it stays blank. With native HLS it turns blank once the tab was hidden.
// A video element that this script creates paints in both cases.
export function recreated(video) {
  const fresh = video.ownerDocument.createElement("video")
  for (const {name, value} of video.attributes) fresh.setAttribute(name, value)
  video.replaceWith(fresh)
  return fresh
}

export const MediaPlayer = {
  mounted() {
    // User-facing text comes from server-rendered data attributes in the session locale.
    // The hook defines no user-facing text of its own.
    this.strings = {...this.el.dataset}
    this.cleanups = []
    this.closed = false
    this.ready = false
    // A podcast plays in an audio element and a PeerTube video in a video element.
    const video = this.el.querySelector("video")
    this.video = video && recreated(video)
    this.media = this.el.querySelector("audio") ?? this.video
    this.message = text => {
      if (!this.closed) this.el.querySelector("[data-player-message]").textContent = text
    }
    this.listen = (target, event, callback) => {
      target.addEventListener(event, callback)
      this.cleanups.push(() => target.removeEventListener(event, callback))
    }
    this.stop = () => {
      if (this.media) this.media.pause()
      else this.youtube?.pauseVideo?.()
    }
    // Position and duration from the media element or the YouTube API.
    // Returns null until the player is ready.
    this.read = () => {
      if (!this.ready) return null
      if (this.media) return {position: this.media.currentTime, duration: this.media.duration}
      return {position: this.youtube.getCurrentTime(), duration: this.youtube.getDuration()}
    }
    this.reporter = createReporter({session: this.el.dataset.session, read: this.read,
      send: (sample, reply) => this.pushEvent("progress", sample, reply),
      stop: this.stop, message: this.message, strings: this.strings})
    this.listen(this.el, "sikio:flush", event => this.reporter.finish(event.detail.done))
    // Dispatches `sikio:ended` on window. PlayerDock then pushes `next` to the server.
    this.ended = () => {
      if (!this.closed) globalThis.window?.dispatchEvent?.(new CustomEvent("sikio:ended"))
    }
    // PlayerDock dispatches `sikio:seek` for a chapter of the playing entry.
    this.listen(this.el, "sikio:seek", event => this.seek(event.detail.position))
    // Keyboard commands dispatched by PlayerDock; see assets/js/player_keys.mjs.
    this.listen(this.el, "sikio:command", event => this.command(event.detail))
    this.listen(document, "visibilitychange", () => {
      if (document.hidden) this.reporter.save(false, true)
    })
    if (this.media) {
      // A PeerTube video reports views to its instance, as the instance's own player does.
      if (this.el.dataset.views) this.views = createViews({send: postView(this.el.dataset.views)})
      this.announce()
      this.mountMedia(this.media)
      this.stream()
      const only = this.el.querySelector("[data-audio-only]")
      if (only) this.listen(only, "click", () => this.switchSound(only))
    } else {
      this.mountYouTube()
    }
  },

  // Binds the hook to a media element. A switch to the sound alone binds the other element, so
  // its listeners are kept apart from the hook's own and removed on the next switch.
  mountMedia(media) {
    this.media = media
    this.unbind = []
    const listen = (target, event, callback) => {
      target.addEventListener(event, callback)
      this.unbind.push(() => target.removeEventListener(event, callback))
    }
    const restore = () => {
      if (this.ready || this.closed) return
      // A seek requested before `loadedmetadata` takes precedence over the saved position.
      const position = this.pendingSeek ?? Number(this.el.dataset.position)
      this.pendingSeek = null
      media.currentTime = Number.isFinite(media.duration) ? Math.min(position, media.duration) : position
      // Loading a source resets the rate, so a switch carries it over here.
      if (this.rate) media.playbackRate = this.rate
      this.ready = true
      if (this.resume !== false) media.play().catch(() => this.message(this.strings.readyAudioManual))
    }
    listen(media, "loadedmetadata", restore)
    listen(media, "timeupdate", () => {
      this.show({position: media.currentTime, duration: media.duration})
      this.placeOnSystem(media)
      this.reporter.save()
      if (!media.paused) this.views?.playing(media.currentTime)
    })
    listen(media, "seeked", () => this.views?.sought())
    listen(media, "play", () => this.show({playing: true}))
    for (const event of ["pause", "ended"]) listen(media, event, () => this.show({playing: false}))
    for (const event of ["pause", "seeked"]) {
      listen(media, event, () => this.reporter.save(false, true))
    }
    listen(media, "ended", () => {
      this.reporter.save(true, true)
      this.ended()
    })
    const failed = this.el.dataset.kind === "peertube" ? this.strings.videoFailed : this.strings.audioFailed
    listen(media, "error", () => this.message(failed))
    // Custom controls for the media element; see assets/js/audio_face.mjs.
    const face = this.el.querySelector("[data-audio-face]")
    if (face) {
      this.unbind.push(bindFace(media, face, {play: this.strings.labelPlay,
        pause: this.strings.labelPause, positionOf: this.strings.positionOf, locale: this.strings.locale}))
    }
    if (media.readyState >= 1) restore()
  },

  // Sets a PeerTube video's source once `data-src` names it. The instance answers after the
  // player mounted, and a reconnect may name it again while it plays. A web file and Safari's own
  // HLS take it as `src`. Other browsers play the playlist through hls.js, capped at 1080p.
  // Larger renditions cost bandwidth without a visible gain in the dock.
  // The worker is off, because the content security policy allows no `blob:` scripts.
  stream() {
    const video = this.video, url = this.el.dataset.src
    if (!video || !url || this.streaming) return
    this.streaming = true
    if (!new URL(url, "https://sikio.invalid").pathname.endsWith(".m3u8") || playsHls(video)) {
      video.src = url
      return
    }
    loadHls(this.el.dataset.hls).then(Hls => {
      if (this.closed) return
      if (!Hls.isSupported()) return this.message(this.strings.videoFailed)
      this.hls = new Hls({enableWorker: false})
      this.hls.on(Hls.Events.MANIFEST_PARSED, (_event, {levels}) => {
        const fitting = levels.map((level, index) => [level.height, index]).filter(([height]) => height <= 1080)
        if (fitting.length > 0) this.hls.autoLevelCapping = fitting.reduce((a, b) => (b[0] > a[0] ? b : a))[1]
      })
      this.hls.on(Hls.Events.ERROR, (_event, {fatal}) => { if (fatal) this.message(this.strings.videoFailed) })
      this.hls.loadSource(url)
      this.hls.attachMedia(video)
    }).catch(() => this.message(this.strings.videoFailed))
  },

  // Switches between the video and its audio-only file at the same place, speed and state.
  // iOS keeps an audio element playing in the background, but not a video element.
  // The hidden video keeps its element and stream, so switching back sets up nothing new.
  switchSound(button) {
    const from = this.media
    this.unbind.forEach(unbind => unbind())
    // Before the video loads, its place is the saved one and its start is still pending.
    this.pendingSeek = this.place()
    this.rate = from.playbackRate
    if (this.ready) this.resume = !from.paused
    this.ready = false
    from.pause()

    let to
    if (this.sound) {
      this.sound.removeAttribute("src")
      this.sound.load()
      this.sound.remove()
      this.sound = null
      to = this.video
      to.hidden = false
    } else {
      to = this.sound = document.createElement("audio")
      to.preload = "metadata"
      to.src = this.el.dataset.audioSrc
      from.hidden = true
      from.after(to)
    }
    button.setAttribute("aria-pressed", String(Boolean(this.sound)))
    this.mountMedia(to)
  },

  async mountYouTube() {
    try {
      const YT = await loadYouTube(this.strings.youtubeUnavailable)
      if (this.closed) return
      this.youtube = new YT.Player(this.el.querySelector("iframe"), {events: {
        onReady: () => {
          if (this.closed) return
          this.ready = true
          // YouTube shows captions for some videos despite `cc_load_policy=0`.
          // The undocumented `unloadModule("captions")` hides them.
          // The player's CC button restores them.
          this.youtube.unloadModule?.("captions")
          if (this.pendingSeek !== null && this.pendingSeek !== undefined) this.seek(this.pendingSeek)
          let previousPosition = this.youtube.getCurrentTime()
          this.poll = setInterval(() => {
            const state = this.youtube.getPlayerState()
            const position = this.youtube.getCurrentTime()
            this.show({playing: [YT.PlayerState.PLAYING, YT.PlayerState.BUFFERING].includes(state),
              position, duration: this.youtube.getDuration()})
            if (state === YT.PlayerState.PLAYING) this.reporter.save(false, jumped(previousPosition, position))
            else if (state === YT.PlayerState.PAUSED && position !== previousPosition) this.reporter.save(false, true)
            previousPosition = position
          }, 1000)
        },
        onStateChange: event => {
          if (!this.ready || this.closed) return
          this.show({playing: event.data === YT.PlayerState.PLAYING})
          if (event.data === YT.PlayerState.ENDED) {
            this.reporter.save(true, true)
            this.ended()
          }
          else if (event.data === YT.PlayerState.PAUSED) this.reporter.save(false, true)
        },
        onError: event => {
          const errors = {
            100: this.strings.youtubeMissing,
            101: this.strings.youtubeBlocked,
            150: this.strings.youtubeBlocked,
            153: this.strings.youtubeOrigin
          }
          this.message(errors[event.data] || this.strings.youtubeUnplayable)
        }
      }})
    } catch (error) {
      this.message(error.message)
    }
  },

  // Each player type seeks differently. The save follows as for a seek in the player's controls.
  // A media element accepts `currentTime` at once, but `restore` would overwrite it on `loadedmetadata`.
  // So a seek before ready is also kept in `pendingSeek` for `restore`.
  // The YouTube API accepts seeks only after `onReady`, so earlier seeks wait in `pendingSeek`.
  seek(position) {
    if (this.media) {
      if (!this.ready) this.pendingSeek = position
      this.media.currentTime = position
    } else if (!this.ready) {
      this.pendingSeek = position
    } else {
      this.pendingSeek = null
      this.youtube?.seekTo?.(position, true)
    }
  },

  command({name, by, direction}) {
    if (name === "toggle") this.toggle()
    else if (name === "skip") this.seek(Math.max(this.place() + by, 0))
    else if (name === "chapter") {
      // Read on each key press. `data-chapters` can change after playback starts.
      const starts = chapters(this.el).map(chapter => chapter.at)
      const at = chapterTarget(starts, this.place(), direction)
      if (at !== null) this.seek(at)
    } else if (name === "mute") this.mute()
    else if (name === "fullscreen") this.fullscreen()
  },

  // Sets `data-playing` and the `--played` CSS custom property on the hook element.
  // The phone capsule's play icon and progress line read them in app.css.
  show({playing, position, duration}) {
    if (playing !== undefined) this.el.dataset.playing = String(playing)
    if (playing !== undefined && this.media && owner === this) {
      systemSession().playbackState = playing ? "playing" : "paused"
    }
    if (Number.isFinite(position) && duration > 0) {
      this.el.style.setProperty("--played", String(Math.min(position / duration, 1)))
    }
  },

  // Media Session metadata and action handlers for a media element: lock screen, control centre,
  // headphones, media keys. The handlers call the hook's own commands.
  // Skips use the action's `seekOffset`, which iOS shows on its buttons.
  // Without one they skip 15 and 30 seconds, like Sikio's buttons.
  // A video iframe has its own media session, which this page cannot access.
  announce() {
    const session = systemSession()
    if (!session || typeof MediaMetadata !== "function") return
    const {title, source, artwork} = this.el.dataset
    owner = this
    session.metadata = new MediaMetadata({title, artist: source, artwork: artwork ? [{src: artwork}] : []})
    const actions = {
      play: () => { if (this.media.paused) this.toggle() },
      pause: () => { if (!this.media.paused) this.toggle() },
      seekbackward: ({seekOffset}) => this.command({name: "skip", by: -offset(seekOffset, 15)}),
      seekforward: ({seekOffset}) => this.command({name: "skip", by: offset(seekOffset, 30)}),
      seekto: ({seekTime}) => this.seek(seekTime)
    }
    for (const [action, handler] of Object.entries(actions)) handle(session, action, handler)
    // The next hook instance can set the Media Session before this one is destroyed.
    // Cleanup then leaves its state unchanged.
    this.cleanups.push(() => {
      if (owner !== this) return
      owner = null
      for (const action of Object.keys(actions)) handle(session, action, null)
      session.metadata = null
      session.playbackState = "none"
    })
  },

  // Updates the Media Session position state. It requires a finite duration.
  placeOnSystem(media) {
    const session = systemSession()
    if (owner !== this || !session?.setPositionState || !Number.isFinite(media.duration)) return
    session.setPositionState({duration: media.duration,
      position: Math.min(media.currentTime, media.duration), playbackRate: media.playbackRate})
  },

  // Before the player is ready, returns the pending seek or the saved start position.
  place() {
    return this.read()?.position ?? this.pendingSeek ?? Number(this.el.dataset.position)
  },

  toggle() {
    if (this.media) {
      if (this.media.paused) this.media.play().catch(() => this.message(this.strings.readyAudioManual))
      else this.media.pause()
    } else if (this.youtube?.getPlayerState) {
      // A buffering video counts as playing, so the toggle pauses it.
      const {PLAYING, BUFFERING} = window.YT?.PlayerState ?? {}
      if ([PLAYING, BUFFERING].includes(this.youtube.getPlayerState())) this.youtube.pauseVideo()
      else this.youtube.playVideo()
    }
  },

  mute() {
    if (this.media) {
      this.media.muted = !this.media.muted
    } else if (this.youtube?.isMuted) {
      if (this.youtube.isMuted()) this.youtube.unMute()
      else this.youtube.mute()
    }
  },

  // Toggles fullscreen for the video element or the iframe.
  // The key press is the user gesture that `requestFullscreen` requires.
  // iOS has no `requestFullscreen` on a video element, only `webkitEnterFullscreen`.
  fullscreen() {
    if (document.fullscreenElement) return document.exitFullscreen?.()
    // The sound alone plays in an audio element and has no picture to enlarge.
    const target = this.sound ? null : this.video ?? this.el.querySelector("iframe")
    if (target?.requestFullscreen) target.requestFullscreen()
    else target?.webkitEnterFullscreen?.()
  },

  disconnected() { this.reporter.disconnect() },
  reconnected() { this.reporter.reconnect() },
  // The hook element has `phx-update="ignore"`, so LiveView does not patch the face's children.
  // A later `data-src` starts the stream. Chapter marks from a later `data-chapters` are drawn.
  updated() {
    this.stream()
    const face = this.el.querySelector("[data-audio-face]")
    if (!face || !this.media || this.el.dataset.chapters === this.drawnChapters) return
    this.drawnChapters = this.el.dataset.chapters
    const duration = this.media.duration > 0 ? this.media.duration : feedLength(face)
    renderMarks(face, chapters(this.el), duration)
  },

  destroyed() {
    if (this.closed) return
    this.closed = true
    this.reporter?.destroy()
    this.cleanups?.forEach(cleanup => cleanup())
    clearInterval(this.poll)
    // LiveView has already removed the element from the DOM.
    // A detached iframe plays nothing and has no `contentWindow`.
    // An exception here would abort LiveView's patch, so iframe players get no pause call.
    // Only media elements keep playing when detached, so only they are paused.
    this.youtube?.destroy?.()
    this.hls?.destroy()
    this.unbind?.forEach(unbind => unbind())
    for (const media of [this.video ?? this.media, this.sound].filter(Boolean)) {
      media.pause()
      media.removeAttribute("src")
      media.load()
    }
  }
}
