export const PlayerDock = {
  mounted() {
    this.busy = false
    this.closed = false
    this.play = event => {
      const id = event.detail.id
      if (String(id) === this.el.dataset.entryId) {
        this.el.querySelector("#player-panel")?.focus()
        return
      }
      this.change("start", {id})
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
      this.pushEvent(event, params, () => {this.busy = false})
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
