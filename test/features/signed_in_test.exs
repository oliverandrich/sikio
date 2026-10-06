# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SignedInTest do
  @moduledoc """
  The shortcut most browser tests start with: a session written into the browser's cookie.

  The passkey ceremony costs about as much as the rest of a typical test. The tests that are
  about signing in keep it; the others are about what comes after, and start here.
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
