# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddressedAccountTest do
  @moduledoc """
  Claiming an instance that addresses its accounts, in a browser.

  The mode is one setting and it reaches the schema, the form, the passkey ceremony and the
  sentence a refusal answers with. A unit test can say each of those separately; only this says
  they agree. The form's field is `type="email"`, so a browser enforces a shape of its own before
  anything server-side is asked — which is exactly the sort of thing markup does not show.
  """
  use SikioWeb.FeatureCase

  alias Sikio.TestConfig

  setup do
    TestConfig.put_env(:sikio, :account_identity, :email)
    :ok
  end

  feature "an account is claimed under an address", %{session: session} do
    virtual_authenticator(session)

    session
    |> open("/")
    |> code_entered()
    |> assert_has(css("input[name=username][type=email]"))
    |> fill_in(css("input[name=username]"), with: "ada@example.org")
    |> click(button("Create your passkey"))
    |> landed_on("/recovery-codes")

    assert Repo.get_by!(User, username: "ada@example.org")
  end

  # The browser refuses it before the server is asked, which is the whole reason the field carries
  # a type rather than a pattern nobody reads.
  #
  # The absence of the alert is what says so. A server that was asked answers `invalid_username`,
  # the hook pushes it back, and the page draws it. Asserting only that no account appeared would
  # pass either way, and did: measured against a field typed `text`, which submits and is refused
  # server-side, this assertion goes red and that one does not.
  feature "a name never leaves the browser", %{session: session} do
    virtual_authenticator(session)

    session
    |> open("/")
    |> code_entered()
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Create your passkey"))
    # The browser refuses to submit an invalid form that validates, so no answer is on its way.
    |> execute_script(
      """
      const form = document.getElementById('claim-form')
      return [form.checkValidity(), form.noValidate, form.querySelector('button').formNoValidate]
      """,
      fn checks -> assert checks == [false, false, false] end
    )
    |> gone(css("[role=alert]"))

    assert Repo.aggregate(User, :count) == 0
  end
end
