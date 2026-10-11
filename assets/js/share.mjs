// SPDX-License-Identifier: AGPL-3.0-or-later

// Shares an item's original page through the system's share sheet. Without one, or when the
// browser refuses it with NotAllowedError, the address goes to the clipboard and `copied` runs.
// Closing the sheet throws AbortError and a second click on an open sheet InvalidStateError.
// Both leave the sheet's outcome alone. Any other failure, or no clipboard outside a secure
// context, runs `failed`.
export async function share(link, {navigator = globalThis.navigator, copied, failed}) {
  try {
    if (navigator?.share) {
      try {
        return await navigator.share(link)
      } catch (error) {
        if (settled.has(error?.name)) return
        if (error?.name !== "NotAllowedError") return failed()
      }
    }
    if (!navigator?.clipboard) return failed()
    await navigator.clipboard.writeText(link.url)
  } catch {
    return failed()
  }
  copied()
}

const settled = new Set(["AbortError", "InvalidStateError"])

// The button names the address in `data-share-url` and the title in `data-share-title`.
// The server answers `link_copied` and `link_not_copied` with a flash in the session's language.
export const Share = {
  mounted() {
    this.onClick = () => {
      const {shareUrl: url, shareTitle: title} = this.el.dataset
      share({title, url}, {copied: () => this.pushEvent("link_copied", {}),
        failed: () => this.pushEvent("link_not_copied", {})})
    }
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() { this.el.removeEventListener("click", this.onClick) }
}
