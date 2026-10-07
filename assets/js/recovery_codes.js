// SPDX-License-Identifier: AGPL-3.0-or-later

// A controller renders this page, so a window click listener handles copying, not a LiveView hook.
window.addEventListener("click", async event => {
  const button = event.target.closest("[data-copy-recovery]")
  if (!button) return

  const status = document.getElementById("copy-status")
  const codes = Array.from(document.querySelectorAll("#recovery-codes li"), item => item.textContent.trim())
  button.disabled = true
  try {
    await navigator.clipboard.writeText(codes.join("\n"))
    status.textContent = button.dataset.copySuccess
  } catch {
    status.textContent = button.dataset.copyError
  } finally {
    button.disabled = false
  }
})
