# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationTest do
  @moduledoc """
  The flow this example exists to show, in a browser.

  Every test here is about a row an instance can hold exactly once — the claim, an invitation that
  is spent by being accepted. Nothing has to clean up between them: Wallaby shares the test's
  sandboxed connection, so each starts from an empty database and rolls back when it ends.
  """
  use SikioWeb.FeatureCase

  alias Sikio.Accounts.Invitation

  # The two preludes the first test walks through with its own assertions, so that the tests about
  # something else can reach their subject in a line.
  defp claim(session, username) do
    session
    |> open("/")
    |> code_entered()
    |> fill_in(css("input[name=username]"), with: username)
    |> click(button("Create your passkey"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Save your recovery codes"))
  end

  # The budget, driven the way a member meets it: the form, the button, the sentence that comes
  # back. A refusal has to leave the link of the invitation already made standing, because that
  # link exists nowhere else.
  feature "a member runs out of invitations and keeps the last link", %{session: session} do
    Sikio.TestConfig.put_budget(:invite, {1, 86_400})

    virtual_authenticator(session)
    claim(session, "ada")

    session
    |> open("/invitations")
    |> fill_in(css("input[name=username]"), with: "grace_hopper")
    |> click(button("Create a link"))
    |> assert_has(css("code", text: "/invite/"))
    |> fill_in(css("input[name=username]"), with: "katherine")
    |> click(button("Create a link"))
    |> assert_has(css("[role=alert]", text: "Too many invitations"))
    |> assert_has(css("code", text: "/invite/"))

    assert Repo.aggregate(Sikio.Accounts.Invitation, :count) == 1
  end

  # The one moment anybody can influence who joins, seen and acted on in a browser: an instance
  # nobody can be removed from has no later one. Rendered rather than asserted against markup,
  # because the list is new and a suite that only reads HTML says nothing about a row a person can
  # read and press.
  feature "a member sees what is outstanding, who made it, and takes one back", %{
    session: session
  } do
    virtual_authenticator(session)
    claim(session, "ada")

    session
    |> open("/invitations")
    |> fill_in(css("input[name=username]"), with: "grace_hopper")
    |> click(button("Create a link"))
    |> assert_has(css("#pending-invitations", text: "grace_hopper"))
    |> assert_has(css("#pending-invitations", text: "Invited by ada"))

    invitation = Repo.one(Invitation)

    # The empty sentence first, then the absence. `assert_has` waits for what it is looking for;
    # a `refute_has` on its own passes the instant it is asked, before the patch that removes the
    # row has arrived — so it would have said nothing either way.
    session
    |> click(css("#invitation-#{invitation.id} button"))
    |> assert_has(css("p", text: "Nothing is waiting to be accepted."))
    |> refute_has(css("#invitation-#{invitation.id}"))

    refute Repo.one(Invitation)
  end

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

  defp main_text(session), do: session |> find(css("main")) |> Element.text()

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
    |> refute_has(css("p", text: "Signed in as"))

    session
    |> open(link)
    # The page names the account it will create and offers no field to change it — the refusal
    # `Invitations.accept/2` would give is turned into an interface that cannot ask for it.
    |> assert_has(css("p", text: "The account will be called"))
    |> refute_has(css("input[name=username]"))
    |> click(button("Accept with a passkey"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Save your recovery codes"))

    session
    |> open("/invitations")
    |> assert_has(css("p", text: "Signed in as grace."))

    assert Repo.get_by(User, username: "grace")
    assert Repo.one(Invitation).accepted_at
  end

  # A used link, an expired one and one nobody ever held are one answer on purpose: anything else
  # tells a guesser which of their guesses was once real.
  feature "a spent link and an invented one are answered exactly alike", %{session: session} do
    virtual_authenticator(session)

    claim(session, "ada")
    link = invite_link(session, "grace")

    session
    |> clear_cookies()
    |> open(link)
    |> click(button("Accept with a passkey"))
    |> landed_on("/recovery-codes")
    |> assert_has(css("h1", text: "Save your recovery codes"))

    spent = session |> clear_cookies() |> open(link) |> main_text()
    invented = session |> open("/invite/a-token-nobody-ever-held") |> main_text()

    # Word for word, because anything else is a signal.
    assert spent == invented
    assert spent =~ "has been used already, or it has expired"
  end

  feature "the instance can be claimed once, and the form does not come back", %{session: session} do
    virtual_authenticator(session)

    claim(session, "ada")

    session
    |> open("/invitations")
    |> assert_has(css("p", text: "Signed in as ada."))
    |> refute_has(css("#claim-form"))
  end
end
