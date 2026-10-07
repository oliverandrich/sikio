// SPDX-License-Identifier: AGPL-3.0-or-later

import {playerKey} from "./player_keys.mjs"

// LiveSocket calls `params` with the view's element on every LiveView join.
// The Phoenix socket calls the same function without a view on every connect.
// Only the dock contains a MediaPlayer, and only while an entry plays.
export function rejoinParams(view) {
  const dock = view?.querySelector("#player-control")
  const session = dock?.querySelector("[phx-hook=MediaPlayer]")?.dataset.session
  return session ? {player_entry: dock.dataset.entryId, player_session: session} : {}
}

export const PlayerDock = {
  mounted() {
    this.busy = false
    this.closed = false
    this.play = event => {
      const id = event.detail.id
      const position = event.detail.position ?? null
      if (String(id) === this.el.dataset.entryId) {
        // For the playing entry, a position seeks the player. Without one, the panel gets focus.
        const media = this.el.querySelector("[phx-hook='MediaPlayer']")
        if (position !== null && media) {
          media.dispatchEvent(new CustomEvent("sikio:seek", {detail: {position}}))
        } else {
          this.el.querySelector("#player-panel")?.focus()
        }
        return
      }
      // The card's cue and chapter links can pass a start position. Null resumes the saved one.
      this.change("start", {id, position})
    }
    this.close = () => this.change("close", {})
    // Runs on `sikio:ended`. After the final save it pushes `next`.
    // The server may then start a queued entry.
    // `sikio:played-on` then names both entries, so a detail of the ended entry can switch.
    this.next = () => {
      const from = this.el.dataset.entryId
      this.change("next", {}, () => {
        // Without a next entry the dock keeps the ended one, and `to` is null.
        const next = this.el.dataset.entryId || null
        const to = next === from ? null : next
        window.dispatchEvent(new CustomEvent("sikio:played-on", {detail: {from, to}}))
      })
    }
    // A window keydown listener on every page dispatches player keys to the active MediaPlayer.
    // Without a player, the toggle key clicks `#start-playback`. Other keys are left alone.
    this.onKey = event => {
      this.tabbed = event.key === "Tab"
      const command = playerKey(event)
      if (!command) return
      const media = this.el.querySelector("[phx-hook='MediaPlayer']")
      const start = !media && command.name === "toggle" && document.getElementById("start-playback")
      if (!media && !start) return
      event.preventDefault()
      if (start) start.click()
      else media.dispatchEvent(new CustomEvent("sikio:command", {detail: command}))
    }
    // A click into a video iframe moves focus there, and its key events do not reach this window.
    // After window `blur`, a zero-delay timeout moves focus from a dock iframe to the panel.
    // Focus reached by Tab stays in the iframe, for the embed's own controls.
    this.onPointer = () => {this.tabbed = false}
    this.onBlur = () => setTimeout(() => {
      const active = document.activeElement
      if (!this.tabbed && active?.tagName === "IFRAME" && this.el.contains(active)) {
        this.el.querySelector("#player-panel")?.focus({preventScroll: true})
      }
    }, 0)
    window.addEventListener("sikio:play", this.play)
    window.addEventListener("sikio:close-player", this.close)
    window.addEventListener("sikio:ended", this.next)
    window.addEventListener("keydown", this.onKey)
    window.addEventListener("blur", this.onBlur)
    window.addEventListener("pointerdown", this.onPointer)
  },
  change(event, params, done = () => {}) {
    if (this.busy || this.closed) return
    this.busy = true
    const proceed = saved => {
      if (this.closed) return
      if (!saved) {this.busy = false; return}
      this.pushEvent(event, params, () => {this.busy = false; done()})
    }
    const media = this.el.querySelector("[phx-hook='MediaPlayer']")
    if (media) media.dispatchEvent(new CustomEvent("sikio:flush", {detail: {done: proceed}}))
    else proceed(true)
  },
  disconnected() {this.busy = false},
  destroyed() {
    this.closed = true
    window.removeEventListener("sikio:play", this.play)
    window.removeEventListener("sikio:close-player", this.close)
    window.removeEventListener("sikio:ended", this.next)
    window.removeEventListener("keydown", this.onKey)
    window.removeEventListener("blur", this.onBlur)
    window.removeEventListener("pointerdown", this.onPointer)
  }
}
