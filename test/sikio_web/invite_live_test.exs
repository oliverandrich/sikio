# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InviteLiveTest do
  @moduledoc """
  The invitation page. The token arrives from the link's fragment, through the hook, after the
  page has joined. No request and no join URL carries it.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Sikio.Accounts.Invitation
  alias Sikio.Repo

  defp invitation(attrs, opts \\ []),
    do: Repo.insert!(Invitation.changeset(%Invitation{}, attrs, opts))

  # What the hook does once the page has joined.
  defp opened(view, token) do
    view |> element("#invitation-link") |> render_hook("invitation-token", %{"token" => token})
  end

  test "the page waits for the token and decides nothing before it", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/invite")

    assert html =~ "Opening your invitation"
    refute html =~ "Accept with a passkey"
    assert has_element?(view, "#invitation-link[phx-hook=InvitationLink]")
  end

  test "an open invitation asks the invitee for a username", %{conn: conn} do
    open = invitation(%{"note" => "Grace"}, addressed: false)
    {:ok, view, _html} = live(conn, ~p"/invite")

    html = opened(view, open.token)

    assert has_element?(view, "#invitation-accept-form input[name=username]")
    refute html =~ "Grace"

    name = unique_username()
    view |> form("#invitation-accept-form", username: name) |> render_submit()

    assert_push_event(view, "ithibati:register", %{token: token, username: ^name})
    assert token == open.token
  end

  test "an addressed invitation names the account and asks for nothing", %{conn: conn} do
    name = unique_username()
    addressed = invitation(%{"username" => name})
    {:ok, view, _html} = live(conn, ~p"/invite")

    assert opened(view, addressed.token) =~ "The account will be called #{name}."
    refute has_element?(view, "input[name=username]")

    view |> element("button", "Accept with a passkey") |> render_click()

    assert_push_event(view, "ithibati:register", %{token: token})
    assert token == addressed.token
  end

  test "a token that opens nothing is answered, and the tab forgets it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invite")

    assert opened(view, "a-token-nobody-ever-held") =~ "has been used already, or it has expired"
    assert_push_event(view, "invitation-token-forget", %{})
  end

  # The page decides nothing before an invitation is open, so no ceremony starts without one.
  test "accepting before the token arrives starts nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invite")

    render_submit(view, "accept", %{"username" => unique_username()})

    refute_push_event(view, "ithibati:register", _)
  end

  # Without a link there is nothing that was used or ran out.
  test "a page opened without a link says so", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invite")

    html = opened(view, "")

    assert html =~ "Open the link from your invitation"
    refute html =~ "has been used already"
  end

  # One mount opens one invitation.
  test "a page takes one token and ignores any after it", %{conn: conn} do
    open = invitation(%{"note" => "Grace"}, addressed: false)
    {:ok, view, _html} = live(conn, ~p"/invite")

    opened(view, open.token)
    html = opened(view, "a-token-nobody-ever-held")

    assert has_element?(view, "#invitation-accept-form")
    refute html =~ "has been used already"
  end
end
