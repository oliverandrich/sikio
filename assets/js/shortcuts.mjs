// SPDX-License-Identifier: AGPL-3.0-or-later

import {elsewhere} from "./player_keys.mjs"

// The overview of every key, opened with ? from anywhere outside a field, or from the account
// menu. The dialog closes on Escape by itself.
export function opensShortcuts(event) {
  return event.key === "?" && !elsewhere(event)
}

export const Shortcuts = {
  mounted() {
    this.open = () => { if (!this.el.open) this.el.showModal() }
    this.onKey = event => {
      if (!opensShortcuts(event)) return
      event.preventDefault()
      this.open()
    }
    window.addEventListener("keydown", this.onKey)
    window.addEventListener("sikio:shortcuts", this.open)
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    window.removeEventListener("sikio:shortcuts", this.open)
  }
}
