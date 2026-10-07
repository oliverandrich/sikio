// SPDX-License-Identifier: AGPL-3.0-or-later

// Chooses the player panel's placement. The panel never moves in the DOM.
// A moved YouTube iframe would reload.
// This module sets `data-place` for app.css and reserves space.
//
// - pinned: over the detail's player slot, when the detail shows the playing entry.
//   On a phone the pinned panel sticks under the top bar as the notes scroll.
// - floating: below lg in all other cases, above the bottom navigation bar, positioned by app.css.
// - compact: from lg in all other cases, a window at the bottom left over sidebar and list.
//   Playback is global and selection is not, so the detail column stays free.
//   Sidebar and list get bottom padding so their content can scroll clear of the window.
export function placement({wide, shown, playing}) {
  if (shown && shown === playing) return "pinned"
  return wide ? "compact" : "floating"
}

const GAP = 16
const WIDE = typeof window === "object" ? window.matchMedia("(width >= 64rem)") : null

// app.css positions the panel by `data-place`: anchor positioning on the slot, or fixed placement.
// This function sets `data-place` and reserves space.
// The slot gets the pinned panel's height. Sidebar and list get bottom padding below the window.
function place() {
  const panel = document.querySelector("#player-panel")
  const detail = document.querySelector("#item-detail")
  const sidebar = document.querySelector("#main-navigation")?.closest("header")
  const list = document.querySelector("#list-pane")
  const shown = detail && detail.offsetParent !== null ? detail.dataset.entryId : null

  const playing = document.querySelector("#player-control")?.dataset.entryId ?? null
  const where = panel ? placement({wide: WIDE.matches, shown, playing}) : "floating"
  if (panel) panel.dataset.place = where

  // A pinned panel gets the slot's width as an inline style, not via anchor-size().
  // With anchor-size(), Safari evaluated the panel's container queries before the width resolved.
  // The audio buttons then used the narrow layout and shifted whenever the time text changed.
  const slot = detail?.querySelector("#player-slot")
  if (panel) panel.style.width = where === "pinned" && slot ? `${slot.clientWidth}px` : ""

  const room = panel ? panel.offsetHeight : 0
  const reserve = where === "compact" ? `${room + 2 * GAP}px` : ""
  if (sidebar) sidebar.style.paddingBottom = reserve
  if (list) list.style.paddingBottom = reserve

  stick(where === "pinned" && !WIDE.matches ? slot : null, panel)
  if (slot) {
    const pinned = panel && where === "pinned"
    slot.style.height = pinned ? `${room}px` : ""
    slot.toggleAttribute("data-pinned", pinned)
    // With `data-playing`, app.css hides the card's audio cue.
    // It is set while the detail shows the playing entry.
    slot.toggleAttribute("data-playing", Boolean(panel) && shown !== null && shown === playing)
  }
}

// On a phone a pinned panel sticks under the top bar once its slot scrolls beneath it.
// app.css reads `data-stuck`. Anchor positioning keeps the panel on its slot otherwise.
// So only the slot's top edge crossing the bar's bottom edge needs detection.
// The IntersectionObserver's root margin extends 100000px upwards.
// It ends at the bar's bottom edge.
// The slot intersects exactly when its top is above that edge, regardless of scroll distance.
// The margin depends on `innerHeight`, so a height change recreates the observer.
let stuck = {slot: null, height: 0, observer: null}

// Whether the slot is under the bar. One callback can deliver several entries, oldest first.
// The last entry is the current state.
export function stuckFrom(entries) {
  return entries.at(-1).isIntersecting
}

function stick(slot, panel) {
  if (slot !== stuck.slot || (slot && innerHeight !== stuck.height)) {
    stuck.observer?.disconnect()
    stuck = {slot, height: innerHeight, observer: null}
    if (slot) {
      const bar = document.querySelector("#masthead")?.offsetHeight ?? 0
      stuck.observer = new IntersectionObserver(entries => {
        const panel = document.querySelector("#player-panel")
        panel?.toggleAttribute("data-stuck", stuckFrom(entries))
      }, {rootMargin: `100000px 0px ${bar - innerHeight}px 0px`})
      stuck.observer.observe(slot)
    }
  }
  if (!slot) panel?.toggleAttribute("data-stuck", false)
}

export const DockPlace = {
  mounted() {
    this.schedule = () => {
      this.frame ||= requestAnimationFrame(() => { this.frame = 0; place() })
    }
    // The panel's height can change without a DOM mutation, for example when a video loads.
    // A ResizeObserver keeps the slot height in sync. `watch` observes the current panel element.
    // ResizeObserver callbacks run after layout and before paint, so no stale frame is painted.
    this.sizes = new ResizeObserver(() => {
      cancelAnimationFrame(this.frame)
      this.frame = 0
      place()
    })
    this.watch = () => {
      const panel = document.querySelector("#player-panel")
      if (panel === this.watched) return
      if (this.watched) this.sizes.unobserve(this.watched)
      if (panel) this.sizes.observe(panel)
      this.watched = panel
    }
    // Text updates inside the audio face do not affect placement, so they are ignored.
    this.observer = new MutationObserver(records => {
      if (records.every(record => record.target.closest?.("[data-audio-face]"))) return
      this.watch()
      this.schedule()
    })
    this.observer.observe(document.body, {childList: true, subtree: true,
      attributes: true, attributeFilter: ["class", "data-entry-id"]})
    window.addEventListener("resize", this.schedule)
    this.watch()
    this.schedule()
  },
  destroyed() {
    stick(null, null)
    cancelAnimationFrame(this.frame)
    this.observer.disconnect()
    this.sizes.disconnect()
    window.removeEventListener("resize", this.schedule)
  }
}
