// SPDX-License-Identifier: AGPL-3.0-or-later

// The list head is sticky and its height changes when the search or the filters open.
// A ResizeObserver writes its height to the pane's --list-head CSS custom property.
// The sticky date headings use it as their top offset.
// Rounded down, so a heading overlaps the head by a subpixel instead of leaving a visible gap.
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
