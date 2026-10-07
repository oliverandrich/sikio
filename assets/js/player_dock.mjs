// SPDX-License-Identifier: AGPL-3.0-or-later

import {playerKey} from "./player_keys.mjs"

// LiveView asks for these on every join of every view. The Phoenix socket shares the option and
// asks without a view on every connect. Only the dock carries a player, and only while it plays.
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
        // A chapter of what already plays moves its player there; play alone shows it.
        const media = this.el.querySelector("[phx-hook='MediaPlayer']")
        if (position !== null && media) {
          media.dispatchEvent(new CustomEvent("sikio:seek", {detail: {position}}))
        } else {
          this.el.querySelector("#player-panel")?.focus()
        }
        return
      }
      // The card's player and a chapter may name a place to begin at; null resumes.
      this.change("start", {id, position})
    }
    this.close = () => this.change("close", {})
    // What played has ended. Once its place is saved the server may start the next in the queue.
    // The page hears which item followed which, so a detail showing the one that ended can follow.
    this.next = () => {
      const from = this.el.dataset.entryId
      this.change("next", {}, () => {
        const to = this.el.dataset.entryId
        if (to && to !== from) window.dispatchEvent(new CustomEvent("sikio:played-on", {detail: {from, to}}))
      })
    }
    // The page keeps the keyboard on every page and hands the player's keys to whichever player
    // plays. Without one, p starts the open item as its play button does; the rest are the page's.
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
    // A click into a video's frame takes the keyboard where the page cannot hear it. The click has
    // reached the frame by then; the page takes the keyboard back and gives it to the panel.
    // Tab into the frame is meant, to reach the embed's own controls, and keeps it there.
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
