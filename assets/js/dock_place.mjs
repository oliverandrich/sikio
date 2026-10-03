// SPDX-License-Identifier: AGPL-3.0-or-later

// Where the player panel goes. It never moves in the DOM, because a moved YouTube iframe reloads,
// so this only changes its position and leaves room for it.
//
// - floating: below lg, above the bottom bar, as the stylesheet places it.
// - pinned: in the detail's player slot under the title, when the detail shows what plays.
// - compact: a window at the bottom left, over the foot of the sidebar and the list, when the
//   detail shows something else or the page has none. Playback is global and selection is not,
//   so the notes get the room. The sidebar and the list keep room to scroll out from under it.
export function placement({wide, shown, playing}) {
  if (!wide) return "floating"
  return shown && shown === playing ? "pinned" : "compact"
}

const GAP = 16
// Twice what fitted inside the sidebar, so a video can still be watched.
const COMPACT_WIDTH = 480
const AWAY = {top: "", left: "", width: "", right: "", bottom: ""}
const WIDE = typeof window === "object" ? window.matchMedia("(width >= 64rem)") : null

// Positions are worked out before anything is written. Clearing first and measuring after would
// shorten the page for one layout on every scroll frame, and the browser would clamp the scroll.
// The slot's height is the one exception: a panel given a new width is measured again.
function place() {
  const panel = document.querySelector("#player-panel")
  const detail = document.querySelector("#item-detail")
  const sidebar = document.querySelector("#main-navigation")?.closest("header")
  const list = document.querySelector("#list-pane")
  const shown = detail && detail.offsetParent !== null ? detail.dataset.entryId : null

  const playing = document.querySelector("#player-control")?.dataset.entryId ?? null
  const where = panel ? placement({wide: WIDE.matches, shown, playing}) : "floating"

  const room = panel ? panel.offsetHeight + GAP : 0
  // Pinned, the panel lies on the detail's player slot, which keeps its height free for it.
  const slot = detail?.querySelector("#player-slot")
  const box = where === "pinned" && slot ? slot.getBoundingClientRect()
    : where === "compact" && sidebar ? sidebar.getBoundingClientRect() : null

  const width = panel?.offsetWidth

  const reserve = where === "compact" ? `${room + GAP}px` : ""
  if (sidebar) sidebar.style.paddingBottom = reserve
  if (list) list.style.paddingBottom = reserve
  if (panel) {
    panel.dataset.place = where
    Object.assign(panel.style,
      where === "pinned" && box ? {top: `${box.top}px`, left: `${box.left}px`, width: `${box.width}px`, right: "auto", bottom: "auto"}
      : where === "compact" && box ? {top: "auto", left: `${box.left + 12}px`, width: `${COMPACT_WIDTH}px`, right: "auto", bottom: `${GAP}px`}
      : AWAY)
  }

  if (slot) {
    const pinned = panel && where === "pinned"
    const height = pinned && panel.offsetWidth !== width ? panel.offsetHeight : room - GAP
    slot.style.height = pinned ? `${height}px` : ""
    slot.toggleAttribute("data-pinned", pinned)
    // Floating on a phone the panel covers nothing, so the card marks that its episode plays.
    slot.toggleAttribute("data-playing", Boolean(panel) && shown !== null && shown === playing)
  }
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
    // From lg the list and the detail scroll on their own, and their scrolling does not bubble.
    // Capturing hears it, and the window's own as well.
    window.addEventListener("scroll", this.schedule, {capture: true, passive: true})
    this.watch()
    this.schedule()
  },
  destroyed() {
    cancelAnimationFrame(this.frame)
    this.observer.disconnect()
    this.sizes.disconnect()
    window.removeEventListener("resize", this.schedule)
    window.removeEventListener("scroll", this.schedule, {capture: true})
  }
}
