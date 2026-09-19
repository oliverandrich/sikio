defmodule SikioWeb.RecoveryTest do
  use SikioWeb.FeatureCase

  alias Ithibati.Identity.RecoveryCodes

  feature "recovery codes sign in without a passkey and cannot be reused", %{session: session} do
    virtual_authenticator(session)

    codes =
      session
      |> open("/")
      |> fill_in(css("input[name=username]"), with: "ada")
      |> click(button("Create your passkey"))
      |> landed_on("/recovery-codes")
      |> all(css("main li"))
      |> Enum.map(&Wallaby.Element.text/1)

    assert length(codes) == 12
    [code | _] = codes

    session
    |> clear_cookies()
    |> open("/recover")
    |> fill_in(css("input[name=code]"), with: code)
    |> click(button("Sign in with a recovery code"))
    |> through_navigation(css("p", text: "Signed in as ada"))

    session
    |> clear_cookies()
    |> open("/recover")
    |> fill_in(css("input[name=code]"), with: code)
    |> click(button("Sign in with a recovery code"))
    |> assert_has(css("[role=alert]"))

    account = Repo.get_by!(User, username: "ada")
    assert RecoveryCodes.remaining(account) == 11
  end
end
