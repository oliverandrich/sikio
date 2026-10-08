// SPDX-License-Identifier: MIT

// A PeerTube embed exchanges postMessage messages with its parent page in the jschannel format.
// jschannel's source documents the format. Messages are JSON strings of four shapes:
// a request `{id, method, params}`, a result `{id, result}`, an error `{id, error, message}`,
// and a notification `{method, params}` without an id.
// Every method name carries the channel scope, `peertube` for PeerTube.
//
// This is a minimal jschannel client for the PeerTube embed. It makes calls and receives the
// status notifications. It publishes no methods of its own.
//
// The embed sends the first message: a ready notification with a publish request.
// It sends nothing else until that is answered. Calls made before then are queued.
//
// An open channel does not mean the embedded player is ready.
// Position requests before that return an error, then 0.
// Callers who need a position wait for the first status update that carries one.
// This module sends nothing on its own.

/**
 * Connects to a PeerTube embed in `iframe`.
 *
 * @param {HTMLIFrameElement} iframe the embed's iframe
 * @param {object} options
 * @param {string} options.origin the embed's origin, such as `https://video.example.org`
 * @param {string} [options.scope] the jschannel scope, `peertube` by default
 * @param {(status: object | string) => void} [options.onStatus] receives status notifications
 * @param {(error: unknown) => void} [options.onError] receives the embed's error notifications
 */
export function connect(iframe, {origin, scope = "peertube", onStatus = () => {}, onError = () => {}} = {}) {
  const ready = `${scope}::__ready`
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

  // Any window can post messages. Only messages from the embed's origin are handled.
  const receive = event => {
    if (destroyed || event.origin !== origin) return

    let message
    try {
      message = JSON.parse(event.data)
    } catch (_error) {
      return
    }
    if (!message || typeof message !== "object") return

    if (message.method === ready) return greet(message.params)
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
      post({method: ready, params: {type: "publish-reply", publish: []}})
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
    const name = message.method.slice(scope.length + 2)

    if (name === "playbackStatusUpdate" || name === "playbackStatusChange") {
      onStatus(message.params)
    } else if (name === "error") {
      onError(message.params)
    }
  }

  window.addEventListener("message", receive)

  return {
    /**
     * Calls `method` on the embed, such as `pause`, `seek` or `setVolume`.
     * A call before the handshake waits for it.
     *
     * @param {string} method the method name without the scope
     * @param {unknown} [params]
     * @returns {Promise<unknown>} the result, or a rejection with the embed's error
     */
    call(method, params) {
      if (destroyed) return Promise.reject(new Error("player closed"))
      const id = nextId++
      const message = {id, method: `${scope}::${method}`, params}
      const answered = new Promise((resolve, reject) => pending.set(id, {resolve, reject}))
      if (open) post(message)
      else queued.push(message)
      return answered
    },

    /** Stops listening and rejects the calls still waiting. */
    destroy() {
      if (destroyed) return
      destroyed = true
      window.removeEventListener("message", receive)
      pending.forEach(({reject}) => reject(new Error("player closed")))
      pending.clear()
    }
  }
}
