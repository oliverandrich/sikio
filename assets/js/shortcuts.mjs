// SPDX-License-Identifier: AGPL-3.0-or-later

import {elsewhere} from "./player_keys.mjs"

// Opens the keyboard shortcut dialog on ? unless `elsewhere` applies.
// The account menu opens it with sikio:show like the other overview dialogs.
// The native dialog element closes on Escape.
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
