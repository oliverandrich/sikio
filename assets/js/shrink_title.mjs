// SPDX-License-Identifier: AGPL-3.0-or-later

// iOS-style large title. An IntersectionObserver watches the [data-large-title] heading.
// The hook sets data-shrunk on its element once the heading has scrolled under it.
// The observer's top root margin is the element's height.
// The group-data-[shrunk] variant on #nav-title then shows the title.
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
