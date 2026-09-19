// This screen is rendered by a controller, so copying does not depend on a LiveView hook.
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
