// SPDX-License-Identifier: AGPL-3.0-or-later

// The list's head stays in view while the list scrolls, and its height changes as the search and
// the filters open. The date headings stick beneath it, so the list pane learns its height.
// Rounded down: a heading then tucks a fraction of a pixel under the head rather than leaving a
// line of the list showing between them.
export function headHeight(head) {
  return `${Math.floor(head.getBoundingClientRect().height)}px`
}

export const ListHead = {
  mounted() {
    const pane = this.el.parentElement
    const measure = () => pane.style.setProperty("--list-head", headHeight(this.el))
    this.observer = new ResizeObserver(measure)
    this.observer.observe(this.el)
    measure()
  },
  destroyed() { this.observer?.disconnect() }
}
