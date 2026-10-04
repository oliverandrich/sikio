// SPDX-License-Identifier: AGPL-3.0-or-later

// The queue's rows are moved by their handles: dragged with a mouse or a finger, or one place at
// a time with the arrow keys while a handle has the focus. The row follows the pointer while it
// is held and the others make room where it would land; where it is let go the server is told
// the place. The list itself comes back in the new order, so nothing here keeps one.

// The place a row lands at: after every other row whose middle the pointer has passed.
export function dropIndex(middles, y) {
  return middles.filter(middle => middle < y).length
}

// How the other `count` rows move while the row from `from` would land at `to`: a place up (-1),
// a place down (1) or not at all, given top to bottom.
export function shifts(from, to, count) {
  return Array.from({length: count}, (_, k) => (from <= k && k < to ? -1 : to <= k && k < from ? 1 : 0))
}

// The place one key moves a row at `index` of `count` rows to, or null for none.
export function keyIndex(key, index, count) {
  if (key === "ArrowUp" && index > 0) return index - 1
  if (key === "ArrowDown" && index < count - 1) return index + 1
  return null
}

export const QueueSort = {
  mounted() {
    this.rows = () => [...this.el.querySelectorAll("article:has([data-move])")]
    this.onDown = event => {
      const handle = event.target.closest?.("[data-move]")
      if (!handle || event.button > 0) return
      event.preventDefault()
      const row = handle.closest("article")
      const rows = this.rows()
      const others = rows.filter(other => other !== row)
      // Measured once, before anything moves, so the rows making room do not move the target.
      const middles = others.map(other => {
        const box = other.getBoundingClientRect()
        return box.top + box.height / 2
      })
      this.drag = {row, others, middles, from: rows.indexOf(row),
        height: row.getBoundingClientRect().height, startY: event.clientY, id: handle.dataset.move}
      handle.setPointerCapture?.(event.pointerId)
      Object.assign(row.style, {position: "relative", zIndex: "1", background: "var(--color-surface)"})
      for (const other of others) other.style.transition = "transform 150ms ease"
    }
    this.onMove = event => {
      if (!this.drag) return
      const drag = this.drag
      drag.row.style.transform = `translateY(${event.clientY - drag.startY}px)`
      const to = dropIndex(drag.middles, event.clientY)
      shifts(drag.from, to, drag.others.length).forEach((shift, k) => {
        drag.others[k].style.transform = shift ? `translateY(${shift * drag.height}px)` : ""
      })
    }
    this.onUp = event => {
      if (!this.drag) return
      const {row, others, middles, id} = this.drag
      this.drag = null
      for (const moved of [row, ...others]) {
        Object.assign(moved.style, {transform: "", position: "", zIndex: "", background: "", transition: ""})
      }
      this.pushEvent("reorder", {id, index: dropIndex(middles, event.clientY)})
    }
    this.onKey = event => {
      const handle = event.target.closest?.("[data-move]")
      if (!handle) return
      const rows = this.rows()
      const index = keyIndex(event.key, rows.indexOf(handle.closest("article")), rows.length)
      if (index === null) return
      event.preventDefault()
      // The handle keeps the focus where the row lands, so the next key moves it on.
      this.pushEvent("reorder", {id: handle.dataset.move, index},
        () => document.getElementById(handle.id)?.focus())
    }
    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onUp)
    this.el.addEventListener("keydown", this.onKey)
  },
  destroyed() {
    this.el.removeEventListener("pointerdown", this.onDown)
    this.el.removeEventListener("pointermove", this.onMove)
    this.el.removeEventListener("pointerup", this.onUp)
    this.el.removeEventListener("pointercancel", this.onUp)
    this.el.removeEventListener("keydown", this.onKey)
  }
}
