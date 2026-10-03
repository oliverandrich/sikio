// SPDX-License-Identifier: AGPL-3.0-or-later

// Which item the player holds lives in the dock, a view of its own the library cannot ask. The
// question that marks a list reads it from the page, and offers to leave that item only then.
export const PlayingEntry = {
  mounted() {
    const id = document.querySelector("#player-control")?.dataset.entryId
    if (!id) return
    this.el.querySelector("input[name=playing_id]").value = id
    this.el.hidden = false
  }
}
