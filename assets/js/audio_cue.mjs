// SPDX-License-Identifier: AGPL-3.0-or-later

import {feedLength, listener, paint, part, skipped} from "./audio_face.mjs"

// The card's player before anything plays. It looks like the dock's and loads nothing: pressing
// play, letting go of the bar or skipping asks the dock to start, at the place chosen. The dock's
// player then lies over it; see assets/js/dock_place.mjs.
export function bindCue(face, {start, positionOf}) {
  const seek = part(face, "seek")
  const {listen, cleanup} = listener()

  listen(part(face, "play"), "click", () => start(null))
  listen(seek, "input", () => paint(face, Number(seek.value), feedLength(face), positionOf))
  listen(seek, "change", () => start(Number(seek.value)))
  for (const button of face.querySelectorAll("[data-audio-skip]")) {
    listen(button, "click", () =>
      start(skipped(Number(seek.value), Number(button.dataset.audioSkip), feedLength(face))))
  }
  return cleanup
}

export const AudioCue = {
  // The face stays one element while the card shows another entry, so the entry is read at the
  // moment it starts, never kept from when the hook mounted.
  mounted() {
    this.cleanup = bindCue(this.el, {
      positionOf: this.el.dataset.positionOf,
      start: position => window.dispatchEvent(new CustomEvent("sikio:play",
        {detail: {id: Number(this.el.dataset.entryId), position}}))
    })
  },
  destroyed() { this.cleanup?.() }
}
