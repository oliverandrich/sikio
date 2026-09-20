import {connect} from "./peertube_embed.mjs"

// One request at a time; keep the newest sample while a save is in flight.
export function createReporter({session, read, send, stop, message, strings, now = Date.now}) {
  let sequence = 0, inFlight = null, pending = null, lastSave = -Infinity
  let connected = true, closed = false, completed = false
  let finishDone = null

  function finishResult(saved) {
    const done = finishDone
    finishDone = null
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
        message(strings.stale)
        finishResult(false)
        return
      }
      message(strings.saved)
      flush()
      if (inFlight === null && !pending) finishResult(true)
    })
  }

  return {
    save(ended = false, force = false) {
      if (closed || (!force && now() - lastSave < 5000)) return
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
      message(strings.disconnected)
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
        message(strings.reconnectFirst)
        return done(false)
      }
      finishDone = done
      this.save(false, true)
      if (inFlight === null && !pending) finishResult(true)
    },
    destroy() { closed = true; pending = null; finishResult(false) }
  }
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
    this.reporter = createReporter({session: this.el.dataset.session,
      read: () => {
        if (!this.ready) return null
        if (this.audio) return {position: this.audio.currentTime, duration: this.audio.duration}
        if (this.peertube) return this.reported
        return {position: this.youtube.getCurrentTime(), duration: this.youtube.getDuration()}
      },
      send: (sample, reply) => this.pushEvent("progress", sample, reply),
      stop: this.stop, message: this.message, strings: this.strings})
    this.listen(this.el, "sikio:flush", event => this.reporter.finish(event.detail.done))
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
          if (!this.ready) {
            this.ready = true
            this.message(this.strings.readyPeertube)
          }
        }

        if (!this.ready) return
        if (state === "ended") this.reporter.save(true, true)
        else if (state === "paused") this.reporter.save(false, true)
        else if (state === "playing") this.reporter.save()
      }
    })
  },

  mountAudio() {
    const audio = this.audio
    const restore = () => {
      if (this.ready || this.closed) return
      const position = Number(this.el.dataset.position)
      audio.currentTime = Number.isFinite(audio.duration) ? Math.min(position, audio.duration) : position
      this.ready = true
      this.message(this.strings.readyAudio)
      audio.play().catch(() => this.message(this.strings.readyAudioManual))
    }
    this.listen(audio, "loadedmetadata", restore)
    this.listen(audio, "timeupdate", () => this.reporter.save())
    for (const event of ["pause", "seeked"]) {
      this.listen(audio, event, () => this.reporter.save(false, true))
    }
    this.listen(audio, "ended", () => this.reporter.save(true, true))
    this.listen(audio, "error", () => this.message(this.strings.audioFailed))
    const speed = this.el.querySelector("#playback-speed")
    this.listen(speed, "change", () => {audio.playbackRate = Number(speed.value)})
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
          this.message(this.strings.readyYoutube)
          let previousPosition = this.youtube.getCurrentTime()
          this.poll = setInterval(() => {
            const state = this.youtube.getPlayerState()
            const position = this.youtube.getCurrentTime()
            if (state === YT.PlayerState.PLAYING) this.reporter.save()
            else if (state === YT.PlayerState.PAUSED && position !== previousPosition) this.reporter.save(false, true)
            previousPosition = position
          }, 1000)
        },
        onStateChange: event => {
          if (!this.ready || this.closed) return
          if (event.data === YT.PlayerState.ENDED) this.reporter.save(true, true)
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

  disconnected() { this.reporter.disconnect() },
  reconnected() { this.reporter.reconnect() },
  destroyed() {
    if (this.closed) return
    this.closed = true
    this.reporter?.destroy()
    this.cleanups?.forEach(cleanup => cleanup())
    clearInterval(this.poll)
    this.stop?.()
    this.peertube?.destroy?.()
    this.youtube?.destroy?.()
    if (this.audio) {
      this.audio.removeAttribute("src")
      this.audio.load()
    }
  }
}
