# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AccountSecurityFeatureTest do
  use SikioWeb.PlaywrightCase

  alias Ithibati.Identity.Passkeys
  alias Ithibati.Identity.RecoveryCodes

  test "a member manages passkeys and replaces recovery codes from the settings", %{conn: conn} do
    first = virtual_authenticator(conn)

    conn
    |> open("/")
    |> code_entered()
    |> fill_in("Username", with: "ada")
    |> click_button("Create your passkey")
    |> assert_path("/recovery-codes")
    |> open("/")
    |> click("#user-menu summary")
    |> click("#settings-link")
    |> assert_path("/account/settings")
    |> click(~s|#settings-account a[href="/account/passkeys"]|)
    |> assert_path("/account/passkeys")
    |> connected()
    |> click_link("Confirm your identity to add a passkey")
    |> assert_path("/account/verify")
    |> connected()
    |> click_button("Confirm with a passkey")
    |> assert_path("/account/passkeys")
    |> connected()
    # A new authenticator models a second device.
    # Ithibati excludes the first device's existing credential from enrollment.
    |> remove_authenticator(first)
    |> tap(&virtual_authenticator/1)
    |> fill_in("#add-passkey-form input[name=label]", "Passkey name", with: "Phone")
    |> click_button("Add a passkey")
    |> assert_has("article input[value=Phone]")

    account = Repo.get_by!(User, username: "ada")
    assert length(Passkeys.list_keys(account)) == 2
    phone = Enum.find(Passkeys.list_keys(account), &(&1.label == "Phone"))

    conn
    |> fill_in("#key-#{phone.id} input[name=label]", "Passkey name", with: "Work phone")
    |> click("#key-#{phone.id} button", "Save name")
    |> assert_has("input[value='Work phone']")
    |> open("/account/recovery-codes")
    |> click("input[name=confirm]")
    |> click_button("Generate new recovery codes")
    |> assert_path("/recovery-codes")
    |> assert_has("button", text: "Copy recovery codes")
    |> assert_has("h1", text: "Save your recovery codes")
  end

  test "a recovery code confirms identity when the passkey is unavailable", %{conn: conn} do
    conn
    |> claimed("ada")

    account = Repo.get_by!(User, username: "ada")
    [code | _] = RecoveryCodes.regenerate(account)

    conn
    |> open("/account/recovery-codes")
    |> click_link("Confirm your identity to generate new codes")
    |> assert_path("/account/verify")
    |> connected()
    |> click("summary", "Use a recovery code instead")
    |> fill_in("Recovery code", with: code)
    |> click_button("Confirm with a recovery code")
    |> assert_path("/account/recovery-codes")
    |> connected()
    |> assert_has("button", text: "Generate new recovery codes")
  end
end
