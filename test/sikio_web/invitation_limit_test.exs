# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationLimitTest do
  @moduledoc """
  How many invitations one account may make.

  Every member may invite, which is this application's decision and a good one among people who
  know each other. It stops being only a question of tidiness once an instance addresses its
  accounts: the form then sends mail to whatever address was typed, through the operator's own
  credentials, and an account somebody else has taken is an open relay pointed at the operator's
  domain.

  The budget is the account's, not the browser's. A session, a name or an address would each let
  the same person start again; the account is the thing that is actually spending.
  """
  # async: false — the budget is application configuration and these set it.
  use SikioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.Invitation
  alias Sikio.Accounts.User
  alias Sikio.Repo
  alias Sikio.TestConfig

  setup do
    TestConfig.put_budget(:invite, {2, 86_400})

    %{conn: signed_in(), other: member()}
  end

  defp member, do: Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))

  defp signed_in(account \\ nil) do
    build_conn() |> init_test_session(%{}) |> Gate.log_in(account || member())
  end

  defp inviting(conn, name) do
    {:ok, view, _html} = live(conn, ~p"/invitations")
    view |> form("#invitation-form", %{"username" => name}) |> render_submit()

    view
  end

  test "a budget is spent, and then it is spent", %{conn: conn} do
    assert inviting(conn, unique_username()) |> render() =~ "/invite/"
    assert inviting(conn, unique_username()) |> render() =~ "/invite/"

    refused = unique_username()
    assert inviting(conn, refused) |> render() =~ "Too many invitations"

    refute Repo.get_by(Invitation, username: refused)
  end

  # Otherwise the budget is a formality: somebody types nonsense until the counter is untouched
  # and then spends the whole of it in one go.
  test "an attempt that fails for another reason still costs", %{conn: conn} do
    inviting(conn, "not a username at all")
    inviting(conn, unique_username())

    wanted = unique_username()
    assert inviting(conn, wanted) |> render() =~ "Too many invitations"

    refute Repo.get_by(Invitation, username: wanted)
  end

  test "another member has their own", %{conn: conn, other: other} do
    inviting(conn, unique_username())
    inviting(conn, unique_username())
    assert inviting(conn, unique_username()) |> render() =~ "Too many invitations"

    theirs = signed_in(other)

    assert inviting(theirs, unique_username()) |> render() =~ "/invite/"
  end

  # The link is the only copy there will ever be, so a refusal that scrolled it off the page
  # would take an invitation that was already made with it.
  test "a refusal leaves the link that is already on screen", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/invitations")

    view |> form("#invitation-form", %{"username" => unique_username()}) |> render_submit()
    view |> form("#invitation-form", %{"username" => unique_username()}) |> render_submit()
    view |> form("#invitation-form", %{"username" => unique_username()}) |> render_submit()

    html = render(view)

    assert html =~ "Too many invitations"
    assert html =~ "/invite/"
  end

  test "and says so in German", %{conn: conn} do
    german = put_req_header(conn, "accept-language", "de")

    inviting(german, unique_username())
    inviting(german, unique_username())

    assert inviting(german, unique_username()) |> render() =~ "Zu viele Einladungen"
  end
end
