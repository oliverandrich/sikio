// SPDX-License-Identifier: AGPL-3.0-or-later

// Chooses the player panel's placement. The panel never moves in the DOM.
// A moved YouTube iframe would reload.
// This module sets `data-place` for app.css and reserves space.
//
// - pinned: over the detail's player slot, when the detail shows the playing entry.
//   It sticks under the top bar on a phone, and to the detail column's top from lg.
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

  const room = panel ? unstuckHeight(panel) : 0
  const reserve = where === "compact" ? `${room + 2 * GAP}px` : ""
  if (sidebar) sidebar.style.paddingBottom = reserve
  if (list) list.style.paddingBottom = reserve

  // From lg the detail column scrolls and clips the slot, so it is the observer's root.
  // Only a pinned panel sticks, so the other places measure nothing for it.
  if (where === "pinned") {
    const root = WIDE.matches ? detail : null
    const below = stickMargin({wide: WIDE.matches, bar: document.querySelector("#masthead")?.offsetHeight ?? 0,
      viewport: innerHeight, column: detail?.clientHeight ?? 0})
    stick(slot, panel, root, below)
  } else {
    stick(null, panel)
  }
  if (slot) {
    const pinned = panel && where === "pinned"
    slot.style.height = pinned ? `${room}px` : ""
    slot.toggleAttribute("data-pinned", pinned)
  }
}

// The panel's height on its slot. From lg app.css caps a stuck video at 40dvh, but the slot
// keeps the full height, so the notes do not move. The attribute returns before the next paint.
function unstuckHeight(panel) {
  if (!panel.hasAttribute("data-stuck")) return panel.offsetHeight
  panel.removeAttribute("data-stuck")
  const height = panel.offsetHeight
  panel.setAttribute("data-stuck", "")
  return height
}

// A pinned panel sticks at an edge once its slot scrolls past it.
// app.css reads `data-stuck`. Anchor positioning keeps the panel on its slot otherwise.
// So only the slot's top edge crossing that edge needs detection.
// The IntersectionObserver's root margin extends 100000px upwards and ends at the edge.
// The slot intersects exactly when its top is above that edge, regardless of scroll distance.
// A changed root or margin recreates the observer.
let stuck = {slot: null, root: null, below: 0, observer: null}

// The bottom root margin that moves the root's bottom edge up to the sticking edge.
// On a phone the root is the viewport, and the edge is the top bar's bottom.
// From lg the root is the detail column, and the edge is its top.
export function stickMargin({wide, bar, viewport, column}) {
  return wide ? -column : bar - viewport
}

// Whether the slot is under the bar. One callback can deliver several entries, oldest first.
// The last entry is the current state.
export function stuckFrom(entries) {
  return entries.at(-1).isIntersecting
}

function stick(slot, panel, root = null, below = 0) {
  if (slot !== stuck.slot || (slot && (root !== stuck.root || below !== stuck.below))) {
    stuck.observer?.disconnect()
    stuck = {slot, root, below, observer: null}
    if (slot) {
      stuck.observer = new IntersectionObserver(entries => {
        const panel = document.querySelector("#player-panel")
        panel?.toggleAttribute("data-stuck", stuckFrom(entries))
      }, {root, rootMargin: `100000px 0px ${below}px 0px`})
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
