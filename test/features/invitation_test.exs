# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationTest do
  @moduledoc """
  The claim of an instance and an invitation accepted with a passkey, in a browser.
  """
  use SikioWeb.FeatureCase

  alias Sikio.Accounts.Invitation

  # The link is shown once and never again — the row holds the token's digest — so it is read here
  # or not at all.
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

    # A fresh session, because an invitation is for somebody who is not signed in — and checked
    # here rather than after the fact: accepting signs you in as the invitee either way, so an
    # assertion further down holds whether or not this line did anything.
    session
    |> clear_cookies()
    |> open("/invitations")
    |> gone(css("p", text: "Signed in as"))

    session
    |> open(link)
    # The page names the account it will create and offers no field to change it — the refusal
    # `Invitations.accept/2` would give is turned into an interface that cannot ask for it.
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
