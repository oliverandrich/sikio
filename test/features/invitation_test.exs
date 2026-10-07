# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationTest do
  @moduledoc """
  Claims an instance and accepts an invitation with a passkey, in a browser.
  """
  use SikioWeb.FeatureCase

  alias Sikio.Accounts.Invitation

  # The page shows the link only once. The row stores only the token digest.
  defp invite_link(session, username) do
    session
    |> open("/invitations")
    |> fill_in(css("input[name=username]"), with: username)
    |> click(button("Create a link"))
    |> find(css("code"))
    |> Element.text()
    |> String.trim()
  end

  feature "the first account claims the instance, and everyone after it arrives on a link", %{
    session: session
  } do
    virtual_authenticator(session)

    session
    |> open("/")
    |> code_entered()
    |> assert_has(css("p", text: "Choose your username and create a passkey"))
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Create your passkey"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Save your recovery codes"))

    link = invite_link(session, "grace")
    assert link =~ "/invite/"

    # A fresh session, because an invitation is for a signed-out visitor.
    # The check is here, not later: accepting signs in as the invitee either way.
    # A later assertion would pass even if `clear_cookies/1` had no effect.
    session
    |> clear_cookies()
    |> open("/invitations")
    |> gone(css("p", text: "Signed in as"))

    session
    |> open(link)
    # The page names the account to be created and has no username field.
    # `Invitations.accept/2` would reject a different name, so the form does not offer one.
    |> assert_has(css("p", text: "The account will be called"))
    |> gone(css("input[name=username]"))
    |> click(button("Accept with a passkey"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Save your recovery codes"))

    session
    |> open("/invitations")
    |> assert_has(css("p", text: "Signed in as grace."))

    assert Repo.get_by(User, username: "grace")
    assert Repo.one(Invitation).accepted_at
  end
end
