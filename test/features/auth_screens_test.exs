# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AuthScreensTest do
  use SikioWeb.FeatureCase

  feature "setup, copy codes, home, login and recovery form a complete flow", %{session: session} do
    virtual_authenticator(session)

    session
    |> open("/")
    |> assert_has(css("#setup-code-form"))
    |> code_entered()
    |> assert_has(css("#claim-form"))
    |> gone(css("input[name=email]"))
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Create your passkey"))
    |> landed_on("/recovery-codes")
    |> execute_script("""
    Object.defineProperty(navigator, 'clipboard', {configurable: true, value: {
      writeText: async text => { window.copiedCodes = text }
    }})
    """)
    |> click(button("Copy recovery codes"))
    |> assert_has(css("#copy-status", text: "Recovery codes copied."))
    |> execute_script(
      """
      return window.copiedCodes === Array.from(document.querySelectorAll('#recovery-codes li'), el => el.textContent.trim()).join('\\n')
      """,
      fn matches -> assert matches end
    )
    |> execute_script("""
    navigator.clipboard.writeText = async () => { throw new Error('permission denied') }
    """)
    |> click(button("Copy recovery codes"))
    |> assert_has(css("#copy-status", text: "Copying was blocked"))
    |> click(link("I've saved my codes. Continue"))
    |> landed_on("/")
    |> assert_has(css("#library-heading"))
    |> open("/recovery-codes")
    |> landed_on("/")
    |> connected()
    |> click(css("#user-menu summary"))
    |> click(link("Sign out"))
    |> landed_on("/login")
    |> gone(css("#recovery-form"))
    |> click(link("Lost your passkey? Use a recovery code"))
    |> assert_has(css("#recovery-form"))
    |> gone(button("Sign in with a passkey"))
    |> click(link("Back to passkey sign-in"))
    |> assert_has(button("Sign in with a passkey"))
    |> click(button("Sign in with a passkey"))
    |> landed_on("/")
    |> open("/invitations")
    |> assert_has(css("p", text: "Signed in as ada."))
  end
end
