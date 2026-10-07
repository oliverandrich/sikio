# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SignedInTest do
  @moduledoc """
  Covers `signed_in/2`, which writes a session cookie into the browser.

  The passkey ceremony takes about as long as the rest of a typical test.
  Sign-in tests run the ceremony. All other features start with `signed_in/2`.
  """
  use SikioWeb.FeatureCase

  feature "a session cookie signs the browser in, for its page and its socket", %{
    session: session
  } do
    account = signed_in(session, "ada")

    session
    |> open("/inbox")
    |> assert_has(css("#library-heading", text: "Inbox"))
    |> assert_has(css("#user-menu summary"))

    assert account.username == "ada"
  end
end
