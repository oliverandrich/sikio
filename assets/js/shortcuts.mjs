// SPDX-License-Identifier: AGPL-3.0-or-later

import {elsewhere} from "./player_keys.mjs"

// The overview of every key, opened with ? from anywhere outside a field. The account menu opens
// it as every overview, with sikio:show. The dialog closes on Escape by itself.
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
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
  }
}
