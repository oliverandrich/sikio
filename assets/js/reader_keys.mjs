// SPDX-License-Identifier: AGPL-3.0-or-later

// j and k move through the reader's list, m marks what is selected and f opens the search. A key
// held with a modifier, typed into a form control or pressed into a player belongs to something
// else: a player uses letters of its own.
export function readerKey(event) {
  if (event.metaKey || event.ctrlKey || event.altKey) return null
  const target = event.target
  if (["INPUT", "SELECT", "TEXTAREA", "AUDIO", "VIDEO", "IFRAME"].includes(target?.tagName) ||
      target?.isContentEditable) return null
  if (event.key === "m" || event.key === "f") return event.repeat ? null : event.key
  return event.key === "j" || event.key === "k" ? event.key : null
}

// Beside the list there is room for the detail, so a wide screen always shows something there.
// On a phone the detail would cover the list, so nothing is chosen for the reader.
export function wantsFirst({wide, selected, rows}) {
  return wide && !selected && rows > 0
}

const WIDE = typeof window === "object" ? window.matchMedia("(width >= 64rem)") : null

// Escape in the search field clears the search and folds the field away.
export function closesSearch(event) {
  return event.key === "Escape" && event.target?.id === "search-input"
}

// How far the list must scroll to show a row between its head's lower edge and the pane's end.
export function reveal({top, bottom, rowTop, rowBottom}) {
  if (rowTop < top) return rowTop - top
  if (rowBottom > bottom) return rowBottom - bottom
  return 0
}

// From lg a newly chosen item starts at the detail's top, and its row is in the list's view.
function follow(id) {
  const detail = document.getElementById("item-detail")
  if (detail) detail.scrollTop = 0
  const pane = document.getElementById("list-pane")
  const row = document.getElementById(`entries-${id}`)
  if (!WIDE.matches || !pane || !row) return
  const head = document.getElementById("list-head").getBoundingClientRect()
  const box = row.getBoundingClientRect()
  pane.scrollTop += reveal({top: head.bottom, bottom: pane.getBoundingClientRect().bottom,
    rowTop: box.top, rowBottom: box.bottom})
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
    this.chooseFirst = () => {
      const {selected, rows} = this.el.dataset
      if (wantsFirst({wide: WIDE.matches, selected, rows: Number(rows)})) this.pushEvent("select_first", {})
    }
    // Turned narrow, an item the page chose for the wide screen would cover the list.
    this.fitWidth = () => WIDE.matches ? this.chooseFirst() : this.pushEvent("release_first", {})
    WIDE.addEventListener("change", this.fitWidth)
    // Opened by its address, an item far down the list has its row brought into view too.
    this.shown = this.el.dataset.selected
    if (this.shown) follow(this.shown)
    this.chooseFirst()
    // The page names what takes the focus once it has rendered the field it opened or closed.
    this.handleEvent("focus", ({id}) => document.getElementById(id)?.focus())
  },
  // A new place or filter may leave nothing chosen, so the page asks again after every patch.
  updated() {
    const {selected} = this.el.dataset
    if (selected && selected !== this.shown) follow(selected)
    this.shown = selected
    this.chooseFirst()
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    WIDE.removeEventListener("change", this.fitWidth)
  }
}
