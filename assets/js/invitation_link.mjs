// SPDX-License-Identifier: AGPL-3.0-or-later

// An invitation link carries its token after `#`, which no request sends and no access log records.
// The token leaves the address before the LiveSocket is built, because it sends the page's URL
// with the join. The tab keeps it in sessionStorage, so a reload still opens the invitation.

const KEY = "invitation-token"
let held = ""

const onPage = () => window.document.getElementById("invitation-link") !== null

// Call before `new LiveSocket(...)`. Returns the token, or "" on any other page.
// Tokens are base64url, so the fragment needs no decoding.
export function captureInvitationToken() {
  held = ""
  if (!onPage() || window.location.hash.length < 2) return ""

  held = window.location.hash.slice(1)
  try { window.sessionStorage.setItem(KEY, held) } catch {}
  window.history.replaceState(window.history.state, "", window.location.pathname + window.location.search)
  return held
}

// Another link opened in the same tab changes only the fragment, which reloads nothing.
export function reloadOnOtherLink() {
  window.addEventListener("hashchange", () => {
    if (onPage()) window.location.reload()
  })
}

function stored() {
  if (held) return held
  try { return window.sessionStorage.getItem(KEY) || "" } catch { return "" }
}

export const InvitationLink = {
  mounted() {
    this.handleEvent("invitation-token-forget", () => {
      held = ""
      try { window.sessionStorage.removeItem(KEY) } catch {}
    })
    this.send()
  },
  // A rejoin mounts the LiveView again, and it waits for the token once more.
  reconnected() { this.send() },
  send() { this.pushEvent("invitation-token", {token: stored()}) },
}
