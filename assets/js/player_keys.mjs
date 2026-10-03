// SPDX-License-Identifier: AGPL-3.0-or-later

// The player's keys. Sikio keeps the keyboard and drives whichever player plays through its API,
// so the keys mean the same for a podcast and for a video, and on every page.
//
//   p                play or pause; Space stays the page's, as Safari presses a focused button
//   Left / Right     back 15 s / ahead 30 s, as the buttons do
//   Shift + arrows   the previous / next chapter
//   u                sound off or on
//   x                fill the screen, for a video
export function playerKey(event) {
  if (elsewhere(event)) return null

  const arrow = {ArrowLeft: -1, ArrowRight: 1}[event.key]
  if (arrow && event.shiftKey) return event.repeat ? null : {name: "chapter", direction: arrow}
  if (arrow) return {name: "skip", by: arrow < 0 ? -15 : 30}
  if (event.repeat) return null

  return {p: {name: "toggle"}, u: {name: "mute"}, x: {name: "fullscreen"}}[event.key] ?? null
}

// A key held with a modifier, typed into a field or pressed in an open dialog belongs to that,
// not to the page. Every key of the page's asks this first.
export function elsewhere(event) {
  const target = event.target
  return event.metaKey || event.ctrlKey || event.altKey || target?.isContentEditable ||
    ["INPUT", "TEXTAREA", "SELECT"].includes(target?.tagName) || Boolean(target?.closest?.("dialog"))
}
