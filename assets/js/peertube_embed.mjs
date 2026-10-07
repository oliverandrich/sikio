// SPDX-License-Identifier: AGPL-3.0-or-later

// A PeerTube embed communicates through postMessage in the jschannel format.
// The format is documented in jschannel's source. Messages are JSON strings of four shapes:
// a request `{id, method, params}`, a result `{id, result}`, an error `{id, error, message}`,
// and a notification `{method, params}` without id.
// Every method name carries the channel scope, `peertube` for PeerTube.
//
// This is a minimal jschannel client. The player needs a few calls and the status updates.
// PeerTube's published embed library bundles its own jschannel implementation.
//
// The embed sends the first message: a ready notification with a publish request.
// It sends nothing else until that is answered. Calls made before then are queued.
//
// An open channel does not mean the embedded player is ready.
// Position requests before that return an error, then 0.
// Saving 0 would overwrite the saved position.
// Callers wait for the first status update with a position, so this module requests none.

const SCOPE = "peertube"
const READY = `${SCOPE}::__ready`

export function connect(iframe, {origin, onStatus = () => {}, onError = () => {}} = {}) {
  let open = false
  let destroyed = false
  let nextId = 1
  const pending = new Map()
  const queued = []

  // A detached iframe has no `contentWindow`. Throwing here would break the code that removed it.
  const post = message => {
    if (destroyed) return
    iframe.contentWindow?.postMessage(JSON.stringify(message), origin)
  }

  const receive = event => {
    if (destroyed || event.origin !== origin) return

    let message
    try {
      message = JSON.parse(event.data)
    } catch (_error) {
      return
    }
    if (!message || typeof message !== "object") return

    if (message.method === READY) return greet(message.params)
    if (message.id !== undefined && message.method) return serve(message)
    if (message.id !== undefined) return answer(message)
    if (typeof message.method === "string") return notify(message)
  }

  // The reply to the ready notification opens the channel and sends the queued calls.
  // This side publishes no methods, so the embed has nothing to call here.
  const greet = params => {
    if (open) return
    open = true
    if (params?.type === "publish-request") {
      post({method: READY, params: {type: "publish-reply", publish: []}})
    }
    while (queued.length) post(queued.shift())
  }

  // Requests from the embed get a null result.
  // An unanswered request leaves a promise pending in the embed.
  const serve = message => post({id: message.id, result: null})

  const answer = message => {
    const waiting = pending.get(message.id)
    if (!waiting) return
    pending.delete(message.id)
    if (message.error) waiting.reject(new Error(message.message || message.error))
    else waiting.resolve(message.result)
  }

  const notify = message => {
    const name = message.method.slice(SCOPE.length + 2)

    if (name === "playbackStatusUpdate" || name === "playbackStatusChange") {
      onStatus(message.params)
    } else if (name === "error") {
      onError(message.params)
    }
  }

  window.addEventListener("message", receive)

  return {
    call(method, params) {
      if (destroyed) return Promise.reject(new Error("player closed"))
      const id = nextId++
      const message = {id, method: `${SCOPE}::${method}`, params}
      const answered = new Promise((resolve, reject) => pending.set(id, {resolve, reject}))
      if (open) post(message)
      else queued.push(message)
      return answered
    },

    destroy() {
      if (destroyed) return
      destroyed = true
      window.removeEventListener("message", receive)
      pending.forEach(({reject}) => reject(new Error("player closed")))
      pending.clear()
    }
  }
}
