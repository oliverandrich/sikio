# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationTest do
  @moduledoc """
  Claims an instance and accepts an invitation with a passkey, in a browser.
  """
  use SikioWeb.FeatureCase

  alias Sikio.Accounts.Invitation

  # The page shows the link only once. The row stores only the token digest.
  defp invite_link(session, note) do
    session
    |> open("/invitations")
    |> fill_in(css("input[name=note]"), with: note)
    |> click(button("Create a link"))
    |> find(css("code"))
    |> Element.text()
    |> String.trim()
  end

  feature "the first account claims the instance, and the next arrives on a link", %{
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

    link = invite_link(session, "Grace, from the meetup")
    assert link =~ "/invite#"

    # A fresh session, because an invitation is for a signed-out visitor.
    # The check is here, not later: accepting signs in as the invitee either way.
    # A later assertion would pass even if `clear_cookies/1` had no effect.
    session
    |> clear_cookies()
    |> open("/invitations")
    |> gone(css("p", text: "Signed in as"))

    # The token leaves the address before the socket joins. The invitee chooses the name.
    session
    |> open(link)
    |> assert_has(css("#invitation-accept-form"))

    assert current_url(session) =~ ~r{/invite$}

    session
    |> fill_in(css("input[name=username]"), with: "grace")
    |> click(button("Accept with a passkey"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Save your recovery codes"))

    session
    |> open("/invitations")
    |> assert_has(css("p", text: "Signed in as grace."))

    assert Repo.get_by(User, username: "grace")
    assert Repo.one(Invitation).accepted_at
  end

  # Refused before the passkey dialog, so no credential is made for a name that cannot be stored.
  feature "a taken name is refused before any passkey is made", %{session: session} do
    virtual_authenticator(session)

    session
    |> open("/")
    |> code_entered()
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Create your passkey"))
    |> landed_on("/recovery-codes")

    link = invite_link(session, "Grace")

    session
    |> clear_cookies()
    |> open(link)
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Accept with a passkey"))
    |> assert_has(css("[role=alert]", text: "That username is taken."))

    refute Repo.one(Invitation).accepted_at
  end

  # A second link opened in the same tab changes only the fragment, which loads nothing by itself.
  feature "another link opened in the same tab opens its own invitation", %{session: session} do
    virtual_authenticator(session)

    session
    |> open("/")
    |> code_entered()
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Create your passkey"))
    |> landed_on("/recovery-codes")

    [_, token] = session |> invite_link("Grace") |> String.split("#")

    session
    |> clear_cookies()
    |> open("/invite#a-token-nobody-ever-held")
    |> assert_has(css("[role=alert]"))
    |> execute_script("window.location.hash = '#{token}'")
    |> assert_has(css("#invitation-accept-form"))
  end
end
