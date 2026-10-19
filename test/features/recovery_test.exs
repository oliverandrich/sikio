# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.RecoveryTest do
  use SikioWeb.PlaywrightCase

  alias Ithibati.Identity.RecoveryCodes

  test "recovery codes sign in without a passkey and cannot be reused", %{conn: conn} do
    codes =
      conn
      |> claimed("ada")
      |> assert_has("main li", count: 12)
      |> value_of(
        "return Array.from(document.querySelectorAll('main li'), li => li.textContent.trim())"
      )

    [code | _] = codes

    conn
    |> clear_cookies()
    |> open("/recover")
    |> fill_in("input[name=code]", "Recovery code", with: code)
    |> click_button("Sign in with a recovery code")
    |> assert_has("#library-heading")
    |> open("/invitations")
    |> assert_has("p", text: "Signed in as ada")

    conn
    |> clear_cookies()
    |> open("/recover")
    |> fill_in("input[name=code]", "Recovery code", with: code)
    |> click_button("Sign in with a recovery code")
    |> assert_has("[role=alert]")

    account = Repo.get_by!(User, username: "ada")
    assert RecoveryCodes.remaining(account) == 11
  end
end
