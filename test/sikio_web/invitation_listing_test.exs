# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationListingTest do
  @moduledoc """
  Seeing what is outstanding, and taking one back.

  Nobody can be removed from this instance once they are in, so the only moment anybody can
  influence who joins is before a link is redeemed. That is what this page makes visible, and
  every member may act on it: dividing members into classes is the answer this application does
  not want.
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
    {:ok, _invitation} = Invitations.open(ada, %{"username" => "grace"})

    {:ok, _view, html} = live(signed_in(ada), ~p"/invitations")

    assert html =~ "grace"
    assert html =~ "ada"
  end

  # A row written before the column existed has nobody in it. `nil` is a real answer, and the
  # list says so rather than inventing a name or leaving a gap somebody reads as one.
  test "a row with no inviter says so" do
    %Invitation{} |> Invitation.changeset(%{"username" => "alan"}) |> Repo.insert!()

    {:ok, _view, html} = live(signed_in(member()), ~p"/invitations")

    assert html =~ "alan"
    assert html =~ "Unknown"
  end

  # By id, not by the name: the invite form carries "grace_hopper" as a placeholder, so a
  # page-wide search for the name passes whatever the list does.
  test "an accepted invitation is not listed" do
    {:ok, invitation} = Invitations.open(member(), %{"username" => "grace"})
    invitation |> Ecto.Changeset.change(accepted_at: DateTime.utc_now()) |> Repo.update!()

    {:ok, view, _html} = live(signed_in(member()), ~p"/invitations")

    refute has_element?(view, "#invitation-#{invitation.id}")
    refute has_element?(view, "#pending-invitations")
  end

  test "any member can withdraw one, and the link stops working at once" do
    {:ok, invitation} = Invitations.open(member("ada"), %{"username" => "grace"})
    token = invitation.token

    {:ok, view, _html} = live(signed_in(member("bob")), ~p"/invitations")

    assert has_element?(view, "#invitation-#{invitation.id}")

    view
    |> element(~s(#invitation-#{invitation.id} button[phx-click="withdraw"]))
    |> render_click()

    refute has_element?(view, "#invitation-#{invitation.id}")
    refute Ithibati.Identity.Invitations.fetch(token)
  end

  # The link is the only copy of the token there will ever be: the row holds its digest, so a link
  # taken off the screen cannot be got back. Taking somebody else's invitation back must not take
  # it with them.
  test "taking one back leaves a link that belongs to another invitation standing" do
    {:ok, old} = Invitations.open(member("ada"), %{"username" => "alan"})

    {:ok, view, _html} = live(signed_in(member("bob")), ~p"/invitations")

    view |> form("#invitation-form", %{"username" => "grace"}) |> render_submit()
    assert render(view) =~ "/invite/"

    html =
      view
      |> element(~s(#invitation-#{old.id} button[phx-click="withdraw"]))
      |> render_click()

    assert html =~ "/invite/"
    refute has_element?(view, "#invitation-#{old.id}")
  end

  # And its own link goes, because it names a row that is not there any more.
  test "taking back the one the link belongs to takes the link with it" do
    {:ok, view, _html} = live(signed_in(member("bob")), ~p"/invitations")

    view |> form("#invitation-form", %{"username" => "grace"}) |> render_submit()
    assert render(view) =~ "/invite/"

    mine = Repo.one(Invitation)

    html =
      view
      |> element(~s(#invitation-#{mine.id} button[phx-click="withdraw"]))
      |> render_click()

    refute html =~ "/invite/"
  end

  # The id comes off the wire and nothing upstream says it is a number. `Repo.get/2` casts to the
  # primary key's type and raises on anything else, which takes the LiveView process down instead
  # of answering the person who pressed the button.
  test "an id that is not one is answered, not raised at" do
    {:ok, view, _html} = live(signed_in(member()), ~p"/invitations")

    assert render_click(view, "withdraw", %{"id" => "not-an-id"}) =~ "no longer there"
  end

  # The id comes off the wire. An invitation that was redeemed between the page rendering and the
  # button being pressed is gone from the library's point of view, and the page has to answer for
  # that rather than raise at whoever pressed it.
  test "withdrawing one that was accepted in the meantime says so and keeps it" do
    {:ok, invitation} = Invitations.open(member("ada"), %{"username" => "grace"})

    {:ok, view, _html} = live(signed_in(member("bob")), ~p"/invitations")

    invitation |> Ecto.Changeset.change(accepted_at: DateTime.utc_now()) |> Repo.update!()

    html =
      view
      |> element(~s(#invitation-#{invitation.id} button[phx-click="withdraw"]))
      |> render_click()

    assert html =~ "not waiting any more"
    assert Repo.aggregate(Invitation, :count) == 1
  end
end
