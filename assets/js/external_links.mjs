// SPDX-License-Identifier: AGPL-3.0-or-later

// Links to other origins open in a new browsing context.
// In an installed web app they would otherwise load inside Sikio's window.
// Templates set a target on known external links. This handles any link without one on click.

// True for an http or https URL with a different origin. mailto: and javascript: URLs return false.
export function leavesApp(href, origin) {
  let url
  try {
    url = new URL(href, origin)
  } catch {
    return false
  }
  return (url.protocol === "https:" || url.protocol === "http:") && url.origin !== origin
}

// Sets target="_blank" and rel="noopener noreferrer" on such a link if it has no target.
export function openAway(event, origin) {
  const link = event.target.closest?.("a[href]")
  if (!link || link.target || !leavesApp(link.href, origin)) return
  link.target = "_blank"
  link.rel = "noopener noreferrer"
}
