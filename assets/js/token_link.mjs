// SPDX-License-Identifier: AGPL-3.0-or-later

// An invitation link and an address confirmation link carry their token after `#`, which no
// request sends and no access log records. The token leaves the address before the LiveSocket is
// built, because it sends the page's URL with the join. The tab keeps it in sessionStorage, so a
// reload still opens the page.

// The hook element of each page, with the name of its storage key and its LiveView events.
const LINKS = {"invitation-link": "invitation-token", "address-link": "address-token"}
// The token caught from this page's address, with the storage key of its page.
let held = {key: null, token: ""}

const onPage = () => Object.keys(LINKS).find(id => window.document.getElementById(id) !== null)

// Call before `new LiveSocket(...)`. Returns the token, or "" on any other page.
// Tokens are base64url, so the fragment needs no decoding.
export function captureLinkToken() {
  held = {key: null, token: ""}
  const page = onPage()
  if (!page || window.location.hash.length < 2) return ""

  held = {key: LINKS[page], token: window.location.hash.slice(1)}
  try { window.sessionStorage.setItem(held.key, held.token) } catch {}
  window.history.replaceState(window.history.state, "", window.location.pathname + window.location.search)
  return held.token
}

// Another link opened in the same tab changes only the fragment, which reloads nothing.
export function reloadOnOtherLink() {
  window.addEventListener("hashchange", () => {
    if (onPage()) window.location.reload()
  })
}

function stored(key) {
  if (held.key === key) return held.token
  try { return window.sessionStorage.getItem(key) || "" } catch { return "" }
}

// Pushes `<key>` with the token and forgets it on `<key>-forget`, where `<key>` is the element's
// entry in LINKS.
export const TokenLink = {
  mounted() {
    this.key = LINKS[this.el.id]
    this.handleEvent(`${this.key}-forget`, () => {
      held = {key: null, token: ""}
      try { window.sessionStorage.removeItem(this.key) } catch {}
    })
    this.send()
  },
  // A rejoin mounts the LiveView again, and it waits for the token once more.
  reconnected() { this.send() },
  send() { this.pushEvent(this.key, {token: stored(this.key)}) },
}
