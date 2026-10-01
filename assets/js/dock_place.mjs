// SPDX-License-Identifier: AGPL-3.0-or-later

// Where the player panel goes. It never moves in the DOM, because a moved YouTube iframe reloads,
// so this only changes its position and leaves room for it.
//
// - floating: below lg, above the bottom bar, as the stylesheet places it.
// - pinned: at the top of the detail column, when the detail shows what plays.
// - compact: a now playing bar at the foot of the sidebar, when the detail shows something else
//   or the page has none. Playback is global and selection is not, so the notes get the room.
export function placement({wide, shown, playing}) {
  if (!wide) return "floating"
  return shown && shown === playing ? "pinned" : "compact"
}

const GAP = 16
const AWAY = {top: "", left: "", width: "", right: "", bottom: ""}
const WIDE = typeof window === "object" ? window.matchMedia("(width >= 64rem)") : null

// Every value is worked out before anything is written. Clearing first and measuring after would
// shorten the page for one layout on every scroll frame, and the browser would clamp the scroll.
function place() {
  const panel = document.querySelector("#player-panel")
  const detail = document.querySelector("#item-detail")
  const sidebar = document.querySelector("#main-navigation")?.closest("header")
  const shown = detail && detail.offsetParent !== null ? detail.dataset.entryId : null

  const where = panel ? placement({
    wide: WIDE.matches,
    shown,
    playing: document.querySelector("#player-control")?.dataset.entryId ?? null
  }) : "floating"

  const room = panel ? panel.offsetHeight + GAP : 0
  const box = where === "pinned" ? detail.getBoundingClientRect()
    : where === "compact" && sidebar ? sidebar.getBoundingClientRect() : null

  if (detail) detail.style.paddingTop = where === "pinned" ? `${room}px` : ""
  if (sidebar) sidebar.style.paddingBottom = where === "compact" ? `${room + GAP}px` : ""
  if (!panel) return

  panel.dataset.place = where
  Object.assign(panel.style,
    where === "pinned" ? {top: `${box.top}px`, left: `${box.left}px`, width: `${box.width}px`, right: "auto", bottom: "auto"}
    : where === "compact" && box ? {top: "auto", left: `${box.left + 12}px`, width: `${box.width - 24}px`, right: "auto", bottom: `${GAP}px`}
    : AWAY)

  // Audio folded out of sight must not take keyboard focus either.
  const audio = panel.querySelector("audio")
  if (audio && audio.inert !== (where === "compact")) audio.inert = where === "compact"
}

export const DockPlace = {
  mounted() {
    this.schedule = () => {
      this.frame ||= requestAnimationFrame(() => { this.frame = 0; place() })
    }
    this.observer = new MutationObserver(this.schedule)
    this.observer.observe(document.body, {childList: true, subtree: true,
      attributes: true, attributeFilter: ["class", "data-entry-id"]})
    window.addEventListener("resize", this.schedule)
    window.addEventListener("scroll", this.schedule, {passive: true})
    this.schedule()
  },
  destroyed() {
    cancelAnimationFrame(this.frame)
    this.observer.disconnect()
    window.removeEventListener("resize", this.schedule)
    window.removeEventListener("scroll", this.schedule)
  }
}
