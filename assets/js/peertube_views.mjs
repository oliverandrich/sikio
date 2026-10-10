// SPDX-License-Identifier: AGPL-3.0-or-later

// Reports a PeerTube view to the video's instance, as the instance's own player does.
// PeerTube's API asks for a report every 5 to 10 seconds while the video plays.
// The instance counts a view after a while, and per `sessionId` unless it counts by IP address.
export function createViews({send, now = Date.now, session = globalThis.crypto.randomUUID()}) {
  let last = -Infinity, seek = false

  return {
    playing(position) {
      if (now() - last < 10000) return
      last = now()
      send({currentTime: Math.floor(position), sessionId: session, ...(seek && {viewEvent: "seek"})})
      seek = false
    },
    sought() { seek = true }
  }
}

// Sends one report with the instance's views API. A failed report is dropped.
// No credentials and no referrer leave this page.
export function postView(url) {
  return body => globalThis.fetch(url, {method: "POST", credentials: "omit", referrerPolicy: "no-referrer",
    headers: {"content-type": "application/json"}, body: JSON.stringify(body)}).catch(() => {})
}
