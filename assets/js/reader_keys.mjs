// SPDX-License-Identifier: AGPL-3.0-or-later

// j and k move through the reader's list, m marks what is selected and f opens the search. A key
// held with a modifier, or typed into a form control, belongs to something else.
export function readerKey(event) {
  if (event.metaKey || event.ctrlKey || event.altKey) return null
  const target = event.target
  if (["INPUT", "SELECT", "TEXTAREA"].includes(target?.tagName) || target?.isContentEditable) return null
  if (event.key === "m" || event.key === "f") return event.repeat ? null : event.key
  return event.key === "j" || event.key === "k" ? event.key : null
}

// Escape in the search field clears the search and folds the field away.
export function closesSearch(event) {
  return event.key === "Escape" && event.target?.id === "search-input"
}

export const ReaderKeys = {
  mounted() {
    this.onKey = event => {
      if (closesSearch(event)) return this.pushEvent("close_search", {})
      const key = readerKey(event)
      if (key === "f") {
        // Otherwise the f lands in the field that is about to take the focus.
        event.preventDefault()
        this.pushEvent("open_search", {})
      } else if (key === "m") this.pushEvent("toggle_mark", {})
      else if (key) this.pushEvent("move", {key})
    }
    window.addEventListener("keydown", this.onKey)
    // The page names what takes the focus once it has rendered the field it opened or closed.
    this.handleEvent("focus", ({id}) => document.getElementById(id)?.focus())
  },
  destroyed() { window.removeEventListener("keydown", this.onKey) }
}
