// SPDX-License-Identifier: AGPL-3.0-or-later

import {bindFace, feedLength, renderMarks} from "./audio_face.mjs"
import {connect} from "../vendor/peertube_embed_client.mjs"

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
      // A paused PeerTube embed keeps sending status updates.
      // Accepting them would refill the queue, and `finish` would never complete.
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

// Video positions arrive at least once per second.
// A change of more than 3 seconds between two readings is a seek.
// The seek can come from a key, a chapter or the embed's controls.
// Audio uses its `seeked` event instead.
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

export const MediaPlayer = {
  mounted() {
    // User-facing text comes from server-rendered data attributes in the session locale.
    // The hook defines no user-facing text of its own.
    this.strings = {...this.el.dataset}
    this.cleanups = []
    this.closed = false
    this.ready = false
    this.audio = this.el.querySelector("audio")
    this.message = text => {
      if (!this.closed) this.el.querySelector("[data-player-message]").textContent = text
    }
    this.listen = (target, event, callback) => {
      target.addEventListener(event, callback)
      this.cleanups.push(() => target.removeEventListener(event, callback))
    }
    this.stop = () => {
      if (this.audio) this.audio.pause()
      else if (this.peertube) this.peertube.call("pause").catch(() => {})
      else this.youtube?.pauseVideo?.()
    }
    // Position and duration from the audio element, the last PeerTube status or the YouTube API.
    // Returns null until the player is ready.
    this.read = () => {
      if (!this.ready) return null
      if (this.audio) return {position: this.audio.currentTime, duration: this.audio.duration}
      if (this.peertube) return this.reported
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
    if (this.audio) this.mountAudio()
    else if (this.el.dataset.kind === "peertube") this.mountPeerTube()
    else this.mountYouTube()
  },

  // The embed sends a status update about twice a second, so the hook does not poll.
  // The first status update with a position marks the player ready.
  // Earlier position requests return 0, and saving 0 would overwrite the saved position.
  mountPeerTube() {
    const iframe = this.el.querySelector("iframe")

    this.peertube = connect(iframe, {
      origin: new URL(iframe.src).origin,
      onError: () => this.message(this.strings.peertubeUnavailable),
      onStatus: status => {
        if (this.closed) return
        const state = typeof status === "string" ? status : status.playbackState

        if (typeof status === "object") {
          this.reported = {position: status.position, duration: status.duration}
          if (!this.silenced && status.volume > 0) this.volume = status.volume
          this.ready = true
        }

        if (!this.ready) return
        this.show({playing: state === "playing", ...this.reported})
        // Every status update repeats state and position. A change to paused forces a save.
        // So does a position change while paused. An unchanged position does not.
        const changed = state !== this.lastState
        const moved = typeof status === "object" && status.position !== this.lastPosition
        const jump = moved && jumped(this.lastPosition, status.position)
        this.lastState = state
        if (typeof status === "object") this.lastPosition = status.position
        if (state === "ended" && changed) {
          this.reporter.save(true, true)
          this.ended()
        }
        else if (state === "paused" && (changed || moved)) this.reporter.save(false, true)
        else if (state === "playing") this.reporter.save(false, jump)
      }
    })
  },

  mountAudio() {
    const audio = this.audio
    this.announce(audio)
    const restore = () => {
      if (this.ready || this.closed) return
      // A seek requested before `loadedmetadata` takes precedence over the saved position.
      const position = this.pendingSeek ?? Number(this.el.dataset.position)
      this.pendingSeek = null
      audio.currentTime = Number.isFinite(audio.duration) ? Math.min(position, audio.duration) : position
      this.ready = true
      audio.play().catch(() => this.message(this.strings.readyAudioManual))
    }
    this.listen(audio, "loadedmetadata", restore)
    this.listen(audio, "timeupdate", () => {
      this.show({position: audio.currentTime, duration: audio.duration})
      this.placeOnSystem(audio)
      this.reporter.save()
    })
    this.listen(audio, "play", () => this.show({playing: true}))
    for (const event of ["pause", "ended"]) this.listen(audio, event, () => this.show({playing: false}))
    for (const event of ["pause", "seeked"]) {
      this.listen(audio, event, () => this.reporter.save(false, true))
    }
    this.listen(audio, "ended", () => {
      this.reporter.save(true, true)
      this.ended()
    })
    this.listen(audio, "error", () => this.message(this.strings.audioFailed))
    // Custom controls for the audio element; see assets/js/audio_face.mjs.
    const face = this.el.querySelector("[data-audio-face]")
    if (face) {
      this.cleanups.push(bindFace(audio, face, {play: this.strings.labelPlay,
        pause: this.strings.labelPause, positionOf: this.strings.positionOf, locale: this.strings.locale}))
    }
    if (audio.readyState >= 1) restore()
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
  // The PeerTube channel queues calls until the channel opens.
  // Audio accepts `currentTime` at once, but `restore` would overwrite it on `loadedmetadata`.
  // So a seek before ready is also kept in `pendingSeek` for `restore`.
  // The YouTube API accepts seeks only after `onReady`, so earlier seeks wait in `pendingSeek`.
  seek(position) {
    if (this.peertube) {
      this.peertube.call("seek", position).catch(() => {})
    } else if (this.audio) {
      if (!this.ready) this.pendingSeek = position
      this.audio.currentTime = position
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
    if (playing !== undefined && this.audio && owner === this) {
      systemSession().playbackState = playing ? "playing" : "paused"
    }
    if (Number.isFinite(position) && duration > 0) {
      this.el.style.setProperty("--played", String(Math.min(position / duration, 1)))
    }
  },

  // Media Session metadata and action handlers for audio: lock screen, control centre, headphones,
  // media keys. The handlers call the hook's own commands.
  // Skips use the action's `seekOffset`, which iOS shows on its buttons.
  // Without one they skip 15 and 30 seconds, like Sikio's buttons.
  // A video iframe has its own media session, which this page cannot access.
  announce(audio) {
    const session = systemSession()
    if (!session || typeof MediaMetadata !== "function") return
    const {title, source, artwork} = this.el.dataset
    owner = this
    session.metadata = new MediaMetadata({title, artist: source, artwork: artwork ? [{src: artwork}] : []})
    const actions = {
      play: () => { if (audio.paused) this.toggle() },
      pause: () => { if (!audio.paused) this.toggle() },
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
  placeOnSystem(audio) {
    const session = systemSession()
    if (owner !== this || !session?.setPositionState || !Number.isFinite(audio.duration)) return
    session.setPositionState({duration: audio.duration,
      position: Math.min(audio.currentTime, audio.duration), playbackRate: audio.playbackRate})
  },

  // Before the player is ready, returns the pending seek or the saved start position.
  place() {
    return this.read()?.position ?? this.pendingSeek ?? Number(this.el.dataset.position)
  },

  toggle() {
    if (this.audio) {
      if (this.audio.paused) this.audio.play().catch(() => this.message(this.strings.readyAudioManual))
      else this.audio.pause()
    } else if (this.peertube) {
      this.peertube.call(this.lastState === "playing" ? "pause" : "play").catch(() => {})
    } else if (this.youtube?.getPlayerState) {
      // A buffering video counts as playing, so the toggle pauses it.
      const {PLAYING, BUFFERING} = window.YT?.PlayerState ?? {}
      if ([PLAYING, BUFFERING].includes(this.youtube.getPlayerState())) this.youtube.pauseVideo()
      else this.youtube.playVideo()
    }
  },

  // The PeerTube embed API has no mute. Mute sets volume 0.
  // Unmute restores the last reported volume.
  mute() {
    if (this.audio) {
      this.audio.muted = !this.audio.muted
    } else if (this.peertube) {
      this.silenced = !this.silenced
      this.peertube.call("setVolume", this.silenced ? 0 : (this.volume || 1)).catch(() => {})
    } else if (this.youtube?.isMuted) {
      if (this.youtube.isMuted()) this.youtube.unMute()
      else this.youtube.mute()
    }
  },

  // Toggles fullscreen for the iframe.
  // The key press is the user gesture that `requestFullscreen` requires.
  fullscreen() {
    if (document.fullscreenElement) document.exitFullscreen?.()
    else this.el.querySelector("iframe")?.requestFullscreen?.()
  },

  disconnected() { this.reporter.disconnect() },
  reconnected() { this.reporter.reconnect() },
  // The hook element has `phx-update="ignore"`, so LiveView does not patch the face's children.
  // Chapter marks from a later `data-chapters` value are rendered here.
  updated() {
    const face = this.el.querySelector("[data-audio-face]")
    if (!face || !this.audio || this.el.dataset.chapters === this.drawnChapters) return
    this.drawnChapters = this.el.dataset.chapters
    const duration = this.audio.duration > 0 ? this.audio.duration : feedLength(face)
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
    // Only audio keeps playing when detached, so only audio is paused.
    this.peertube?.destroy?.()
    this.youtube?.destroy?.()
    if (this.audio) {
      this.audio.pause()
      this.audio.removeAttribute("src")
      this.audio.load()
    }
  }
}
