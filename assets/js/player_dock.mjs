// SPDX-License-Identifier: AGPL-3.0-or-later

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
    window.addEventListener("sikio:play", this.play)
    window.addEventListener("sikio:close-player", this.close)
  },
  change(event, params) {
    if (this.busy || this.closed) return
    this.busy = true
    const proceed = saved => {
      if (this.closed) return
      if (!saved) {this.busy = false; return}
      this.pushEvent(event, params, reply => {
        this.busy = false
        // The player that starts takes the keyboard. Its letters mean something else: m mutes,
        // f fills the screen, j and k seek. Clicking anywhere else gives them back.
        if (reply?.started) this.el.querySelector("#player-panel :is(iframe, [data-audio-play])")?.focus()
      })
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
  }
}
