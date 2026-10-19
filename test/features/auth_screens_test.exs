# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AuthScreensTest do
  use SikioWeb.PlaywrightCase

  test "setup, copy codes, home and login form a flow, and recovery toggles", %{conn: conn} do
    virtual_authenticator(conn)

    conn
    |> open("/")
    |> assert_has("#setup-code-form")
    |> code_entered()
    |> assert_has("#claim-form")
    |> refute_has("input[name=email]")
    |> fill_in("Username", with: "ada")
    |> click_button("Create your passkey")
    |> assert_path("/recovery-codes")
    |> evaluate("""
    Object.defineProperty(navigator, 'clipboard', {configurable: true, value: {
      writeText: async text => { window.copiedCodes = text }
    }})
    """)
    |> click_button("Copy recovery codes")
    |> assert_has("#copy-status", text: "Recovery codes copied.")
    |> evaluate(
      """
      window.copiedCodes === Array.from(document.querySelectorAll('#recovery-codes li'), el => el.textContent.trim()).join('\\n')
      """,
      fn matches -> assert matches end
    )
    |> evaluate("""
    navigator.clipboard.writeText = async () => { throw new Error('permission denied') }
    """)
    |> click_button("Copy recovery codes")
    |> assert_has("#copy-status", text: "Copying was blocked")
    |> click_link("I've saved my codes. Continue")
    |> assert_path("/")
    |> assert_has("#library-heading")
    |> open("/recovery-codes")
    |> assert_path("/")
    |> connected()
    |> click("#user-menu summary")
    |> click_link("Sign out")
    |> assert_path("/login")
    |> refute_has("#recovery-form")
    |> click_link("Lost your passkey? Use a recovery code")
    |> assert_has("#recovery-form")
    |> refute_has("button", text: "Sign in with a passkey")
    |> click_link("Back to passkey sign-in")
    |> assert_has("button", text: "Sign in with a passkey")
    |> click_button("Sign in with a passkey")
    |> assert_path("/")
    |> open("/invitations")
    |> assert_has("p", text: "Signed in as ada.")
  end
end
