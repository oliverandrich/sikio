// SPDX-License-Identifier: AGPL-3.0-or-later

import {bindFace, feedLength, renderMarks} from "./audio_face.mjs"
import {connect} from "./peertube_embed.mjs"

// One request at a time; keep the newest sample while a save is in flight.
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
      // A saved place is the normal case and says nothing. It takes back its own warning only.
      if (warned) { warned = false; message("") }
      flush()
      if (inFlight === null && !pending) finishResult(true)
    })
  }

  return {
    save(ended = false, force = false) {
      // Finishing, the stopped player's last place is already asked for. A paused PeerTube embed
      // keeps reporting, and taking each report would keep the queue from ever running dry.
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

// A video reports its place every second or faster, so a larger step between two reports is a
// seek: by key, by chapter or in the embed's own controls. Audio has an event for that.
export function jumped(previous, position) {
  return Math.abs(position - previous) > 3
}

// Where a chapter key goes from `position`: ahead, the next chapter's start; back, the start of
// the chapter that plays, or the one before it just after a start, as players do.
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

// The player that last told the system what plays, so another one's cleanup leaves it alone.
let owner = null

// The chapters of what plays, as the page names them now: where each begins and its title.
const chapters = el => JSON.parse(el.dataset.chapters || "[]")

const systemSession = () => globalThis.navigator?.mediaSession

const offset = (given, fallback) => (given > 0 ? given : fallback)

// A browser throws on an action it does not know; the others still work.
function handle(session, action, handler) {
  try { session.setActionHandler(action, handler) } catch { /* not offered here */ }
}

export const MediaPlayer = {
  mounted() {
    // Every sentence this hook can show is rendered by the server, so the player speaks the
    // language the rest of the page speaks. Nothing here holds a second copy of the wording.
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
    // Where the player is and how long it lasts: the audio's own, what the instance last reported,
    // YouTube's. Nothing before the player knows itself.
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
    // The end, said once to the page: the dock may go on with the queue.
    this.ended = () => {
      if (!this.closed) globalThis.window?.dispatchEvent?.(new CustomEvent("sikio:ended"))
    }
    // A chapter moves the player. Each player is moved its own way; the save follows as for a
    // seek by hand.
    this.listen(this.el, "sikio:seek", event => this.seek(event.detail.position))
    // The page's keys, routed here by the dock; see assets/js/player_keys.mjs.
    this.listen(this.el, "sikio:command", event => this.command(event.detail))
    this.listen(document, "visibilitychange", () => {
      if (document.hidden) this.reporter.save(false, true)
    })
    if (this.audio) this.mountAudio()
    else if (this.el.dataset.kind === "peertube") this.mountPeerTube()
    else this.mountYouTube()
  },

  // The instance tells us where it is about twice a second, so nothing here polls. Its first
  // report is also what says the player exists: asked any earlier it answers zero, and saving a
  // zero would throw away the place somebody left off at.
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
        // The embed repeats its state and place with every report. Becoming paused is worth a
        // forced save, and so is a seek while paused; the same place again is not.
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
      // A chapter chosen meanwhile is where it starts, rather than the saved place.
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
    // Sikio's own controls over the audio; see assets/js/audio_face.mjs.
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
          // YouTube shows captions for some videos unasked, and no parameter turns them off. This
          // undocumented call does, and the player's CC button brings them back.
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

  // A chapter moves the player, each its own way; the save follows as for a seek by hand. The
  // PeerTube channel queues what it is asked before the embed opens. Audio takes a place at once,
  // but restoring the saved one once it is ready would undo it, so a chapter chosen before then
  // is kept for that. YouTube answers only once ready, and a chapter chosen earlier waits.
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
      // Read at each press: the page may learn the chapters after the player started.
      const starts = chapters(this.el).map(chapter => chapter.at)
      const at = chapterTarget(starts, this.place(), direction)
      if (at !== null) this.seek(at)
    } else if (name === "mute") this.mute()
    else if (name === "fullscreen") this.fullscreen()
  },

  // Whether it plays and how far it has come, on the element for the stylesheet: the phone's
  // capsule shows play or pause and a line along its foot from these.
  show({playing, position, duration}) {
    if (playing !== undefined) this.el.dataset.playing = String(playing)
    if (playing !== undefined && this.audio && owner === this) {
      systemSession().playbackState = playing ? "playing" : "paused"
    }
    if (Number.isFinite(position) && duration > 0) {
      this.el.style.setProperty("--played", String(Math.min(position / duration, 1)))
    }
  },

  // The system's own controls for an episode: the lock screen, the control centre, headphones and
  // media keys. They name the episode and drive it through the player's own commands. A skip goes
  // as far as the system's button says, as iOS draws its own; without an offset as Sikio's do. A
  // video's frame has a session of its own, which Sikio cannot reach.
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
    // The next episode's player may announce itself before this one is gone. What it set stays.
    this.cleanups.push(() => {
      if (owner !== this) return
      owner = null
      for (const action of Object.keys(actions)) handle(session, action, null)
      session.metadata = null
      session.playbackState = "none"
    })
  },

  // Where the episode is, for the system's scrubber. Only a known length can be shown.
  placeOnSystem(audio) {
    const session = systemSession()
    if (owner !== this || !session?.setPositionState || !Number.isFinite(audio.duration)) return
    session.setPositionState({duration: audio.duration,
      position: Math.min(audio.currentTime, audio.duration), playbackRate: audio.playbackRate})
  },

  // Until a player knows itself, it is where it is about to start.
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
      // A video that buffers is meant to play, so the key pauses it as well.
      const {PLAYING, BUFFERING} = window.YT?.PlayerState ?? {}
      if ([PLAYING, BUFFERING].includes(this.youtube.getPlayerState())) this.youtube.pauseVideo()
      else this.youtube.playVideo()
    }
  },

  // PeerTube has no mute of its own, so the volume it last reported is put back.
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

  // The frame fills the screen; a key press is the gesture the browser asks for.
  fullscreen() {
    if (document.fullscreenElement) document.exitFullscreen?.()
    else this.el.querySelector("iframe")?.requestFullscreen?.()
  },

  disconnected() { this.reporter.disconnect() },
  reconnected() { this.reporter.reconnect() },
  // The face is rendered once and left alone, so chapters the page learns later are drawn here.
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
    // LiveView has already taken the element out of the page. A frame out of the page plays
    // nothing and has no window to tell, and an exception here would abort LiveView's patch, so
    // the channels close first and only audio, which keeps playing detached, is paused.
    this.peertube?.destroy?.()
    this.youtube?.destroy?.()
    if (this.audio) {
      this.audio.pause()
      this.audio.removeAttribute("src")
      this.audio.load()
    }
  }
}
