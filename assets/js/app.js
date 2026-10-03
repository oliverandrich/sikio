// SPDX-License-Identifier: AGPL-3.0-or-later

// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import "./recovery_codes"
import {hooks as ithibatiHooks} from "ithibati"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/sikio"
import topbar from "../vendor/topbar"
import {MediaPlayer} from "./media_player.mjs"
import {PlayerDock, rejoinParams} from "./player_dock.mjs"
import {ReaderKeys} from "./reader_keys.mjs"
import {DockPlace} from "./dock_place.mjs"
import {AudioCue} from "./audio_cue.mjs"
import {Shortcuts} from "./shortcuts.mjs"
import {ListHead} from "./list_head.mjs"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  // The reader's offset from UTC in minutes, which decides where the library's "today" begins.
  params: view => ({
    _csrf_token: csrfToken,
    time_zone_offset: -new Date().getTimezoneOffset(),
    ...rejoinParams(view),
  }),
  hooks: {...colocatedHooks, ...ithibatiHooks, MediaPlayer, PlayerDock, ReaderKeys, DockPlace, AudioCue, Shortcuts, ListHead},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
// An overview dialog opens over the page when a sikio:show event reaches it; see Layouts.overview.
// A browser gives the focus to the first button, which then shows its ring. A dialog marked
// autofocus takes the focus itself, which browsers do not do for it; Tab still reaches the buttons.
window.addEventListener("sikio:show", event => {
  const dialog = event.target
  if (!(dialog instanceof HTMLDialogElement) || dialog.open) return
  dialog.showModal()
  if (dialog.hasAttribute("autofocus")) dialog.focus()
})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
