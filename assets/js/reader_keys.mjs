// SPDX-License-Identifier: AGPL-3.0-or-later

import {elsewhere} from "./player_keys.mjs"

// j and k move the selection, m toggles its mark and f opens the search.
// Keys with a modifier, in a form control, on a media element or iframe, or in an open dialog are
// ignored. Repeats of m and f are ignored. Player keys are in assets/js/player_keys.mjs.
export function readerKey(event) {
  if (elsewhere(event) || ["AUDIO", "VIDEO", "IFRAME"].includes(event.target?.tagName)) return null
  if (event.key === "m" || event.key === "f") return event.repeat ? null : event.key
  return event.key === "j" || event.key === "k" ? event.key : null
}

// The player's title links to the playing entry on its source page, which works on any page.
// In the library a plain click pushes "show" instead, so the list stays rendered.
// Other buttons and modifier clicks return null and keep the default navigation.
export function shownEntry(event) {
  if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return null
  return event.target?.closest?.("[data-show-entry]")?.dataset.showEntry ?? null
}

// After play-on, returns the next entry id for the detail, or null.
// Only when the ended entry is selected and the rendered list contains the next one.
export function followed({selected, from, to, listed}) {
  return to && listed && selected === from ? to : null
}

// From lg the detail column sits beside the list, so an empty selection gets the first row.
// Below lg the detail replaces the list, so nothing is selected automatically.
export function wantsFirst({wide, selected, rows}) {
  return wide && !selected && rows > 0
}

const WIDE = typeof window === "object" ? window.matchMedia("(width >= 64rem)") : null

// Escape in the search input closes the search.
export function closesSearch(event) {
  return event.key === "Escape" && event.target?.id === "search-input"
}

// Scroll delta that brings a row between the list head's bottom edge and the pane's bottom edge.
export function reveal({top, bottom, rowTop, rowBottom}) {
  if (rowTop < top) return rowTop - top
  if (rowBottom > bottom) return rowBottom - bottom
  return 0
}

// Scrolls the detail to the top. From lg it also scrolls the selected row into the list pane.
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
        // Otherwise the f is typed into the search input once it receives focus.
        event.preventDefault()
        this.pushEvent("open_search", {})
      } else if (key === "m") this.pushEvent("toggle_mark", {})
      else if (key) this.pushEvent("move", {key})
    }
    window.addEventListener("keydown", this.onKey)
    // Capture phase runs before LiveView's link handling, which would navigate to the source page.
    this.onClick = event => {
      const id = shownEntry(event)
      if (id === null) return
      event.preventDefault()
      event.stopPropagation()
      this.pushEvent("show", {id})
    }
    document.addEventListener("click", this.onClick, {capture: true})
    // assets/js/player_dock.mjs dispatches sikio:played-on after an entry ends; `to` is null
    // when no entry follows.
    this.onPlayedOn = ({detail: {from, to}}) => {
      const selected = this.el.dataset.selected
      const listed = Boolean(to && document.getElementById(`entries-${to}`))
      const id = followed({selected, from, to, listed})
      if (id) this.pushEvent("show", {id})
      // The server checks whether the list still contains the ended entry.
      // The list in the DOM may not have reloaded yet.
      else if (!to && selected === from) this.pushEvent("played_out", {id: from})
    }
    window.addEventListener("sikio:played-on", this.onPlayedOn)
    this.chooseFirst = () => {
      const {selected, rows} = this.el.dataset
      if (wantsFirst({wide: WIDE.matches, selected, rows: Number(rows)})) this.pushEvent("select_first", {})
    }
    // Below lg an automatically selected entry would hide the list, so the server releases it.
    this.fitWidth = () => WIDE.matches ? this.chooseFirst() : this.pushEvent("release_first", {})
    WIDE.addEventListener("change", this.fitWidth)
    // An entry opened by URL may be far down the list, so its row is scrolled into view.
    this.shown = this.el.dataset.selected
    if (this.shown) follow(this.shown)
    this.chooseFirst()
  },
  // A new place or filter may leave no selection, so this runs again after every update.
  updated() {
    const {selected} = this.el.dataset
    if (selected && selected !== this.shown) follow(selected)
    this.shown = selected
    this.chooseFirst()
  },
  destroyed() {
    window.removeEventListener("keydown", this.onKey)
    document.removeEventListener("click", this.onClick, {capture: true})
    window.removeEventListener("sikio:played-on", this.onPlayedOn)
    WIDE.removeEventListener("change", this.fitWidth)
  }
}
