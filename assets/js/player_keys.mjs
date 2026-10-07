// SPDX-License-Identifier: AGPL-3.0-or-later

// Player keyboard shortcuts. Sikio handles the keydown events and calls the active player's API.
// The keys therefore act the same for audio and video, on every page.
//
//   p                play or pause; Space is unbound, Safari uses it to press a focused button
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

// True for a key event with Meta, Ctrl or Alt, from an editable element or form control, or
// inside an open dialog. Every page shortcut checks this first.
export function elsewhere(event) {
  const target = event.target
  return event.metaKey || event.ctrlKey || event.altKey || target?.isContentEditable ||
    ["INPUT", "TEXTAREA", "SELECT"].includes(target?.tagName) || Boolean(target?.closest?.("dialog[open]"))
}
