# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddressedAccountTest do
  @moduledoc """
  Claims an instance in email account mode, in a browser.

  `:account_identity` affects the schema, the form, the passkey ceremony and the error message.
  Unit tests cover each part. This test checks that they agree.
  The form field is `type="email"`, so the browser validates it before submitting.
  Markup assertions cannot show that validation.
  """
  use SikioWeb.PlaywrightCase

  alias Sikio.TestConfig

  setup do
    TestConfig.put_env(:sikio, :account_identity, :email)
    :ok
  end

  test "an account is claimed under an address", %{conn: conn} do
    virtual_authenticator(conn)

    conn
    |> open("/")
    |> code_entered()
    |> assert_has("input[name=username][type=email]")
    |> fill_in("Email address", with: "ada@example.org")
    |> click_button("Create your passkey")
    |> assert_path("/recovery-codes")

    assert Repo.get_by!(User, username: "ada@example.org")
  end

  # The browser rejects the input before submitting. So the field uses a type, not a pattern.
  #
  # The missing alert shows this. A submitted form gets `invalid_username`, rendered as an alert.
  # Asserting only that no account exists passes either way.
  # Measured with a field of type `text`: this assertion fails, the account count does not.
  test "a name never leaves the browser", %{conn: conn} do
    virtual_authenticator(conn)

    conn
    |> open("/")
    |> code_entered()
    |> fill_in("Email address", with: "ada")
    |> click_button("Create your passkey")
    # Constraint validation blocks submitting an invalid form, so no server response follows.
    |> script(
      """
      const form = document.getElementById('claim-form')
      return [form.checkValidity(), form.noValidate, form.querySelector('button').formNoValidate]
      """,
      fn checks -> assert checks == [false, false, false] end
    )
    |> refute_has("[role=alert]")

    assert Repo.aggregate(User, :count) == 0
  end
end
