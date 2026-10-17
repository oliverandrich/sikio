// SPDX-License-Identifier: AGPL-3.0-or-later

import {copyText} from "./copy_text.mjs"

// A controller renders this page, so a window click listener handles copying, not a LiveView hook.
window.addEventListener("click", async event => {
  const button = event.target.closest("[data-copy-recovery]")
  if (!button) return

  const status = document.getElementById("copy-status")
  const codes = Array.from(document.querySelectorAll("#recovery-codes li"), item => item.textContent.trim())
  button.disabled = true
  const copied = await copyText(codes.join("\n"))
  status.textContent = copied ? button.dataset.copySuccess : button.dataset.copyError
  button.disabled = false
})
