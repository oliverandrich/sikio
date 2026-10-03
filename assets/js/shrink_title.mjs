// SPDX-License-Identifier: AGPL-3.0-or-later

// On a phone the page opens on a large heading, and the bar at the top shows the title instead
// once that heading has scrolled under it, as an iPhone's apps do. The page marks its heading
// with data-large-title; the bar is told by data-shrunk, which the stylesheet reads.
export const ShrinkTitle = {
  mounted() { this.watch() },
  updated() { this.watch() },
  watch() {
    const heading = document.querySelector("[data-large-title]")
    if (heading === this.watched) return
    this.observer?.disconnect()
    this.watched = heading
    this.el.toggleAttribute("data-shrunk", false)
    if (!heading) return
    this.observer = new IntersectionObserver(([entry]) => {
      this.el.toggleAttribute("data-shrunk", !entry.isIntersecting)
    }, {rootMargin: `-${this.el.offsetHeight}px 0px 0px 0px`})
    this.observer.observe(heading)
  },
  destroyed() { this.observer?.disconnect() }
}
