// SPDX-License-Identifier: AGPL-3.0-or-later

// A PeerTube embed answers through postMessage, in the format jschannel documents in its own
// source: JSON strings carrying either a request `{id, method, params}`, an answer `{id, result}`
// or `{id, error, message}`, or a notification `{method, params}` with no id. Every method name
// carries the channel's scope, which for PeerTube is `peertube`.
//
// This is that client and nothing more: what the player needs is a handful of calls and the
// progress the embed volunteers. The library PeerTube publishes brings a second one of its own
// for a protocol whose whole grammar is four shapes.
//
// The embed speaks first. It sends a ready notification asking to publish, and says nothing
// further until that is answered, so anything asked before then waits rather than being lost.
//
// Opening the channel is not the same moment as the player behind it being usable. Asked any
// earlier the embed answers its position with an error, and with a zero once it stops erring,
// which would overwrite the place somebody left off at. Whoever needs to know waits for the
// first reported position instead, so nothing here asks.

const SCOPE = "peertube"
const READY = `${SCOPE}::__ready`

export function connect(iframe, {origin, onStatus = () => {}, onError = () => {}} = {}) {
  let open = false
  let destroyed = false
  let nextId = 1
  const pending = new Map()
  const queued = []

  // A frame taken out of the page has no window. There is nobody left to tell, and throwing here
  // would break whatever removed it.
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

  // Answering the request is what opens the channel. Nothing is published from this side: the
  // embed is asked things, it is never asked to call back.
  const greet = params => {
    if (open) return
    open = true
    if (params?.type === "publish-request") {
      post({method: READY, params: {type: "publish-reply", publish: []}})
    }
    while (queued.length) post(queued.shift())
  }

  // Nothing of this side is bound, so the embed asks little. Answering matters anyway: an
  // unanswered call leaves it waiting on a promise of its own.
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
