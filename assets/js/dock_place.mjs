// SPDX-License-Identifier: AGPL-3.0-or-later

// Where the player panel goes. It never moves in the DOM, because a moved YouTube iframe reloads,
// so this only names its place for the stylesheet and leaves room for it.
//
// - pinned: in the detail's player slot under the title, when the detail shows what plays. On a
//   phone a video stays under the top bar as the notes scroll.
// - floating: below lg anywhere else, above the bottom bar, as the stylesheet places it.
// - compact: a window at the bottom left, over the foot of the sidebar and the list, when the
//   detail shows something else or the page has none. Playback is global and selection is not,
//   so the notes get the room. The sidebar and the list keep room to scroll out from under it.
export function placement({wide, shown, playing}) {
  if (shown && shown === playing) return "pinned"
  return wide ? "compact" : "floating"
}

const GAP = 16
const WIDE = typeof window === "object" ? window.matchMedia("(width >= 64rem)") : null

// Where the panel lies is the stylesheet's, by data-place: anchored to the detail's player slot,
// or fixed at the bottom left. This decides which, and keeps the room it needs: the slot as tall as
// the pinned panel, and the sidebar and the list free at their foot beneath the window.
function place() {
  const panel = document.querySelector("#player-panel")
  const detail = document.querySelector("#item-detail")
  const sidebar = document.querySelector("#main-navigation")?.closest("header")
  const list = document.querySelector("#list-pane")
  const shown = detail && detail.offsetParent !== null ? detail.dataset.entryId : null

  const playing = document.querySelector("#player-control")?.dataset.entryId ?? null
  const where = panel ? placement({wide: WIDE.matches, shown, playing}) : "floating"
  if (panel) panel.dataset.place = where

  // A pinned panel is as wide as its slot, written here rather than taken from anchor-size():
  // Safari measured the panel as a container before that width was known, laid the audio's
  // buttons out for a narrow one and shifted them whenever the time changed.
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
    // Floating on a phone the panel covers nothing, so the card marks that its episode plays.
    slot.toggleAttribute("data-playing", Boolean(panel) && shown !== null && shown === playing)
  }
}

// On a phone a pinned video stays under the top bar once its slot has scrolled beneath it; the
// stylesheet reads data-stuck. The panel follows its slot by itself, so only the slot's top edge
// crossing the bar's needs telling. The observer's root reaches from far above the screen down to
// the bar's edge: the slot meets it exactly when its top has passed that edge, however much of it
// is in view and however far a scroll jumps. The edge is measured, so a new height builds it again.
let stuck = {slot: null, height: 0, observer: null}

function stick(slot, panel) {
  if (slot !== stuck.slot || (slot && innerHeight !== stuck.height)) {
    stuck.observer?.disconnect()
    stuck = {slot, height: innerHeight, observer: null}
    if (slot) {
      const bar = document.querySelector("#masthead")?.offsetHeight ?? 0
      stuck.observer = new IntersectionObserver(([entry]) => {
        const panel = document.querySelector("#player-panel")
        panel?.toggleAttribute("data-stuck", entry.isIntersecting)
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
    // A panel changes height without a mutation, a video loading or a style changing. The slot
    // under it follows. The panel comes and goes, so whichever is there is the one observed.
    // The observer runs after layout and before paint, so placing here leaves no stale frame.
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
    // The audio's own controls change their text as it plays, which moves nothing.
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
