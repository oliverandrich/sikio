// SPDX-License-Identifier: AGPL-3.0-or-later

// A link that leaves Sikio opens outside it. Installed as an app, a page would otherwise load
// inside Sikio's own window. The markup names a target for the links it knows; this catches one
// it forgot, at the moment it is clicked.

// Whether an address leads to another host on the web. Mail and scripts are not places to open.
export function leavesApp(href, origin) {
  let url
  try {
    url = new URL(href, origin)
  } catch {
    return false
  }
  return (url.protocol === "https:" || url.protocol === "http:") && url.origin !== origin
}

// A click on such a link without a target of its own gives it a tab of its own.
export function openAway(event, origin) {
  const link = event.target.closest?.("a[href]")
  if (!link || link.target || !leavesApp(link.href, origin)) return
  link.target = "_blank"
  link.rel = "noopener noreferrer"
}
