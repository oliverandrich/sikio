// SPDX-License-Identifier: AGPL-3.0-or-later

import {feedLength, listener, namesHovered, paint, part, skipped} from "./audio_face.mjs"

// The card's audio controls before playback. Same markup as the dock's; it loads no media.
// Play, a seek change or a skip calls `start` with the chosen position.
// The dock's panel is then positioned over it; see assets/js/dock_place.mjs.
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
  namesHovered(face, listen)
  return cleanup
}

export const AudioCue = {
  // LiveView patches the same element for another entry, so data-entry-id is read on each start,
  // not at mount.
  mounted() {
    this.cleanup = bindCue(this.el, {
      positionOf: this.el.dataset.positionOf,
      start: position => window.dispatchEvent(new CustomEvent("sikio:play",
        {detail: {id: Number(this.el.dataset.entryId), position}}))
    })
  },
  destroyed() { this.cleanup?.() }
}
