// SPDX-License-Identifier: AGPL-3.0-or-later

// j and k move through the reader's list. A key held with a modifier, or typed into a form
// control, belongs to something else.
export function movement(event) {
  if (event.metaKey || event.ctrlKey || event.altKey) return null
  const target = event.target
  if (["INPUT", "SELECT", "TEXTAREA"].includes(target?.tagName) || target?.isContentEditable) return null
  return event.key === "j" || event.key === "k" ? event.key : null
}

export const ReaderKeys = {
  mounted() {
    this.onKey = event => {
      const key = movement(event)
      if (key) this.pushEvent("move", {key})
    }
    window.addEventListener("keydown", this.onKey)
  },
  destroyed() { window.removeEventListener("keydown", this.onKey) }
}
