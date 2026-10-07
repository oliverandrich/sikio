// SPDX-License-Identifier: AGPL-3.0-or-later

// Reorders queue rows by their [data-move] handles, with pointer events or the arrow keys.
// During a drag the row follows the pointer and the other rows shift by CSS transforms.
// On pointerup the hook pushes "reorder" with the new index. The server renders the new order.

// Drop index: the number of other rows whose vertical middle is above the pointer.
export function dropIndex(middles, y) {
  return middles.filter(middle => middle < y).length
}

// Shift of each of the other `count` rows for a move from `from` to `to`, top to bottom:
// -1 one place up, 1 one place down, 0 unchanged.
export function shifts(from, to, count) {
  return Array.from({length: count}, (_, k) => (from <= k && k < to ? -1 : to <= k && k < from ? 1 : 0))
}

// Target index for ArrowUp or ArrowDown on the row at `index` of `count`, or null.
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
      // Measured once before any transform, so shifted rows do not change the drop targets.
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
      // Refocuses the handle after the reply, so the next arrow key moves the same row again.
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
