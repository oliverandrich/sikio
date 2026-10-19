# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationTest do
  @moduledoc """
  Claims an instance and accepts an invitation with a passkey, in a browser.
  """
  use SikioWeb.PlaywrightCase

  alias Sikio.Accounts.Invitation

  # The page shows the link only once. The row stores only the token digest.
  defp invite_link(conn, note) do
    conn
    |> open("/invitations")
    |> fill_in("Who is it for?", with: note)
    |> click_button("Create a link")
    |> assert_has("code")
    |> value_of("return document.querySelector('code').textContent.trim()")
  end

  test "the first account claims the instance, and the next arrives on a link", %{conn: conn} do
    virtual_authenticator(conn)

    conn
    |> open("/")
    |> code_entered()
    |> assert_has("p", text: "Choose your username and create a passkey")
    |> fill_in("Username", with: "ada")
    |> click_button("Create your passkey")
    |> assert_path("/recovery-codes")
    |> assert_has("h1", text: "Save your recovery codes")

    link = invite_link(conn, "Grace, from the meetup")
    assert link =~ "/invite#"

    # A fresh session, because an invitation is for a signed-out visitor.
    # The check is here, not later: accepting signs in as the invitee either way.
    # A later assertion would pass even if `clear_cookies/1` had no effect.
    conn
    |> clear_cookies()
    |> open("/invitations")
    |> refute_has("p", text: "Signed in as")

    # The token leaves the address before the socket joins. The invitee chooses the name.
    conn
    |> open(link)
    |> assert_has("#invitation-accept-form")
    |> script("return location.href", fn url -> assert url =~ ~r{/invite$} end)
    |> fill_in("Username", with: "grace")
    |> click_button("Accept with a passkey")
    |> assert_path("/recovery-codes")
    |> assert_has("h1", text: "Save your recovery codes")
    |> open("/invitations")
    |> assert_has("p", text: "Signed in as grace.")

    assert Repo.get_by(User, username: "grace")
    assert Repo.one(Invitation).accepted_at
  end

  # Headless Chrome may refuse the clipboard, so the page records what it would write. A new link
  # mounts a new button, so the last link's check does not carry over.
  test "the copy button copies each new link, and a new link starts without a check", %{
    conn: conn
  } do
    conn
    |> claimed("ada")

    first = invite_link(conn, "Grace")

    conn
    |> evaluate("""
    Object.defineProperty(navigator, 'clipboard', {configurable: true, value: {
      writeText: async text => { window.copiedText = text }
    }})
    """)
    |> click_button("Copy link")
    |> assert_has("[phx-hook=CopyText][data-copied]")
    |> script("return window.copiedText", fn copied -> assert copied == first end)
    |> fill_in("Who is it for?", with: "Ada")
    |> click_button("Create a link")
    |> assert_has("[phx-hook=CopyText]:not([data-copy-text='#{first}'])")
    # Read once, not awaited: the old check clears itself after two seconds.
    |> script(
      "return document.querySelector('[phx-hook=CopyText]').hasAttribute('data-copied')",
      fn copied -> refute copied end
    )
    |> click_button("Copy link")
    |> assert_has("[phx-hook=CopyText][data-copied]")
    |> script("return window.copiedText", fn copied -> refute copied == first end)
  end

  # Refused before the passkey dialog, so no credential is made for a name that cannot be stored.
  test "a taken name is refused before any passkey is made", %{conn: conn} do
    conn
    |> claimed("ada")

    link = invite_link(conn, "Grace")

    conn
    |> clear_cookies()
    |> open(link)
    |> fill_in("Username", with: "ada")
    |> click_button("Accept with a passkey")
    |> assert_has("[role=alert]", text: "That username is taken.")

    refute Repo.one(Invitation).accepted_at
  end

  # A second link opened in the same tab changes only the fragment, which loads nothing by itself.
  test "another link opened in the same tab opens its own invitation", %{conn: conn} do
    conn
    |> claimed("ada")

    [_, token] = conn |> invite_link("Grace") |> String.split("#")

    conn
    |> clear_cookies()
    |> open("/invite#a-token-nobody-ever-held")
    |> assert_has("[role=alert]")
    |> evaluate("window.location.hash = '#{token}'")
    |> assert_has("#invitation-accept-form")
  end
end
