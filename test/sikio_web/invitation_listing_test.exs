# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationListingTest do
  @moduledoc """
  Listing and withdrawing pending invitations.

  Every member may view invitations and withdraw their own; an administrator withdraws any. An
  administrator may remove a member who invited somebody; the invitation then names a former
  member.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.Invitation
  alias Sikio.Accounts.User
  alias Sikio.Invitations
  alias Sikio.Repo

  defp member(name \\ nil),
    do: Repo.insert!(User.changeset(%User{}, %{username: name || unique_username()}))

  defp signed_in(account), do: build_conn() |> init_test_session(%{}) |> Gate.log_in(account)

  test "the page lists what is outstanding, for whom and by whom" do
    ada = member("ada")
    {:ok, _invitation} = Invitations.open(ada, %{"note" => "grace"})

    {:ok, _view, html} = live(signed_in(ada), ~p"/invitations")

    assert html =~ "grace"
    assert html =~ "ada"
  end

  # Rows created before the inviter column existed have a `nil` inviter.
  # The list shows "Unknown" instead of a blank cell.
  test "a row with no inviter says so" do
    %Invitation{} |> Invitation.changeset(%{"username" => "alan"}) |> Repo.insert!()

    {:ok, _view, html} = live(signed_in(member()), ~p"/invitations")

    assert html =~ "alan"
    assert html =~ "Unknown"
  end

  # Checks element ids, because the form placeholder "grace_hopper" contains the name "grace".
  # A page-wide text search would always match.
  # An administrator may remove the inviter. The invitation stays and names a former member.
  test "a row whose inviter was removed names a former member" do
    gone = member()
    {:ok, invitation} = Invitations.open(gone, %{"note" => "grace"})
    Repo.delete!(gone)

    {:ok, view, _html} = live(signed_in(member()), ~p"/invitations")
    assert has_element?(view, "#invitation-#{invitation.id}", "former member")
  end

  test "an accepted invitation is not listed" do
    {:ok, invitation} = Invitations.open(member(), %{"note" => "grace"})
    invitation |> Ecto.Changeset.change(accepted_at: DateTime.utc_now()) |> Repo.update!()

    {:ok, view, _html} = live(signed_in(member()), ~p"/invitations")

    refute has_element?(view, "#invitation-#{invitation.id}")
    refute has_element?(view, "#pending-invitations")
  end

  test "the inviter withdraws their own, and the link stops working at once" do
    ada = member("ada")
    {:ok, invitation} = Invitations.open(ada, %{"note" => "grace"})
    token = invitation.token

    {:ok, view, _html} = live(signed_in(ada), ~p"/invitations")

    view
    |> element(~s(#invitation-#{invitation.id} button[phx-click="withdraw"]))
    |> render_click()

    refute has_element?(view, "#invitation-#{invitation.id}")
    refute Ithibati.Identity.Invitations.fetch(token)
  end

  # Another member sees the invitation but cannot take it back, not even by a forged event.
  test "another member cannot withdraw it" do
    {:ok, invitation} = Invitations.open(member("ada"), %{"note" => "grace"})

    {:ok, view, _html} = live(signed_in(member("bob")), ~p"/invitations")

    assert has_element?(view, "#invitation-#{invitation.id}")
    refute has_element?(view, ~s(#invitation-#{invitation.id} button[phx-click="withdraw"]))

    render_click(view, "withdraw", %{"id" => to_string(invitation.id)})
    assert has_element?(view, "#invitation-#{invitation.id}")
    assert render(view) =~ "Only the member who sent it, or an administrator, can take it back."
  end

  test "an administrator withdraws anybody's" do
    {:ok, invitation} = Invitations.open(member("ada"), %{"note" => "grace"})
    admin = Repo.insert!(%User{username: unique_username(), admin: true})

    {:ok, view, _html} = live(signed_in(admin), ~p"/invitations")

    view
    |> element(~s(#invitation-#{invitation.id} button[phx-click="withdraw"]))
    |> render_click()

    refute has_element?(view, "#invitation-#{invitation.id}")
  end

  # The link is long and copied by hand otherwise. The status line is the hook's, so a patch
  # must not reset it. It sits outside the link's box, so the two are not nested live regions.
  test "a new link has a copy button beside it" do
    {:ok, view, _html} = live(signed_in(member()), ~p"/invitations")

    view |> form("#invitation-form", %{"note" => "grace"}) |> render_submit()

    assert has_element?(view, "#invitation-link-text", "/invite#")

    assert has_element?(
             view,
             ~s(button[phx-hook=CopyText][data-copy-text^="http"][data-copy-status^=copy-link-status])
           )

    assert has_element?(view, ~s([id^=copy-link-status][role=status][phx-update=ignore]))
    refute has_element?(view, ~s([role=status] [id^=copy-link-status]))

    # An icon button: the name is for screen readers and the tooltip, not a second label.
    assert has_element?(
             view,
             ~s(button[phx-hook=CopyText][aria-label="Copy link"][title="Copy link"] svg)
           )

    refute has_element?(view, "button[phx-hook=CopyText]", "Copy link")
  end

  # A new link mounts a new button, so the last link's check does not carry over.
  test "each new link has a button of its own" do
    {:ok, view, _html} = live(signed_in(member()), ~p"/invitations")

    view |> form("#invitation-form", %{"note" => "grace"}) |> render_submit()
    first = Repo.get_by!(Invitation, note: "grace")
    assert has_element?(view, "#copy-invitation-link-#{first.id}")

    view |> form("#invitation-form", %{"note" => "ada"}) |> render_submit()
    second = Repo.get_by!(Invitation, note: "ada")
    assert has_element?(view, "#copy-invitation-link-#{second.id}")
    refute has_element?(view, "#copy-invitation-link-#{first.id}")
  end

  # The row stores only the token digest, so the displayed link is the only copy of the token.
  # Withdrawing another invitation must keep the displayed link.
  test "taking one back leaves a link that belongs to another invitation standing" do
    ada = member("ada")
    {:ok, old} = Invitations.open(ada, %{"note" => "alan"})

    {:ok, view, _html} = live(signed_in(ada), ~p"/invitations")

    view |> form("#invitation-form", %{"note" => "grace"}) |> render_submit()
    assert render(view) =~ "/invite#"

    html =
      view
      |> element(~s(#invitation-#{old.id} button[phx-click="withdraw"]))
      |> render_click()

    assert html =~ "/invite#"
    refute has_element?(view, "#invitation-#{old.id}")
  end

  # Withdrawing the invitation behind the displayed link removes the link.
  test "taking back the one the link belongs to takes the link with it" do
    {:ok, view, _html} = live(signed_in(member("bob")), ~p"/invitations")

    view |> form("#invitation-form", %{"note" => "grace"}) |> render_submit()
    assert render(view) =~ "/invite#"

    mine = Repo.one(Invitation)

    html =
      view
      |> element(~s(#invitation-#{mine.id} button[phx-click="withdraw"]))
      |> render_click()

    refute html =~ "/invite#"
  end

  # The id is client input and may not be numeric. `Repo.get/2` raises on an uncastable id.
  # The raise would crash the LiveView process instead of rendering a message.
  test "an id that is not one is answered, not raised at" do
    {:ok, view, _html} = live(signed_in(member()), ~p"/invitations")

    assert render_click(view, "withdraw", %{"id" => "not-an-id"}) =~ "no longer there"
  end

  # An invitation can be accepted between render and click. Ithibati then treats it as gone.
  # The page renders a message instead of raising, and the row remains.
  test "withdrawing one that was accepted in the meantime says so and keeps it" do
    ada = member("ada")
    {:ok, invitation} = Invitations.open(ada, %{"note" => "grace"})

    {:ok, view, _html} = live(signed_in(ada), ~p"/invitations")

    invitation |> Ecto.Changeset.change(accepted_at: DateTime.utc_now()) |> Repo.update!()

    html =
      view
      |> element(~s(#invitation-#{invitation.id} button[phx-click="withdraw"]))
      |> render_click()

    assert html =~ "not waiting any more"
    assert Repo.aggregate(Invitation, :count) == 1
  end
end
