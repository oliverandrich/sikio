// SPDX-License-Identifier: AGPL-3.0-or-later

// The playing entry's id is in the dock, a separate LiveView, not in the library's assigns.
// The hook copies it from #player-control into the mark-all form and unhides the option.
export const PlayingEntry = {
  mounted() {
    const id = document.querySelector("#player-control")?.dataset.entryId
    if (!id) return
    this.el.querySelector("input[name=playing_id]").value = id
    this.el.hidden = false
  }
}
