# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.InvitationsTest do
  @moduledoc """
  Tests listing, creating and withdrawing pending invitations.

  Sikio owns the table and Ithibati owns the invariants. `pending_query/0` returns the predicate
  that `fetch/1` uses. `withdraw/1` rechecks acceptance inside its delete. Sikio duplicates
  neither check.
  """
  use Sikio.DataCase, async: true

  alias Sikio.Accounts.Invitation
  alias Sikio.Accounts.User
  alias Sikio.Invitations
  alias Sikio.Repo

  defp member(name \\ nil),
    do: Repo.insert!(User.changeset(%User{}, %{username: name || unique_username()}))

  describe "open/2" do
    test "records who made the invitation" do
      ada = member("ada")

      {:ok, invitation} = Invitations.open(ada, %{"username" => "grace"})

      assert invitation.invited_by_id == ada.id
    end

    # The inviter comes from the account argument, not the params.
    # Otherwise a submitted `invited_by_id` could name any member.
    test "and not whoever the parameters claim" do
      ada = member("ada")
      someone_else = member("bob")

      {:ok, invitation} =
        Invitations.open(ada, %{"username" => "grace", "invited_by_id" => someone_else.id})

      assert invitation.invited_by_id == ada.id
    end

    test "refuses a name that is not one, and writes nothing" do
      assert {:error, changeset} = Invitations.open(member(), %{"username" => "not a name"})
      refute changeset.valid?
      assert Repo.aggregate(Invitation, :count) == 0
    end
  end

  describe "pending/0" do
    test "brings the inviter with it, and says nothing for a row that has none" do
      ada = member("ada")
      {:ok, _with} = Invitations.open(ada, %{"username" => "grace"})

      %Invitation{}
      |> Invitation.changeset(%{"username" => "alan"})
      |> Repo.insert!()

      by_name = Map.new(Invitations.pending(), &{&1.username, &1.invited_by})

      assert %{username: "ada"} = by_name["grace"]
      assert by_name["alan"] == nil
    end

    test "leaves out an invitation that was accepted" do
      {:ok, invitation} = Invitations.open(member(), %{"username" => "grace"})

      invitation
      |> Ecto.Changeset.change(accepted_at: DateTime.utc_now())
      |> Repo.update!()

      assert Invitations.pending() == []
    end

    test "leaves out one that has run out" do
      {:ok, invitation} = Invitations.open(member(), %{"username" => "grace"})

      invitation
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

      assert Invitations.pending() == []
    end
  end

  describe "withdraw/1" do
    test "takes one back, and the link stops working at once" do
      {:ok, invitation} = Invitations.open(member(), %{"username" => "grace"})
      token = invitation.token

      assert {:ok, _withdrawn} = Invitations.withdraw(invitation)

      assert Invitations.pending() == []
      refute Ithibati.Identity.Invitations.fetch(token)
    end

    # Ithibati rechecks acceptance inside the delete.
    # This prevents withdrawing an invitation during a concurrent redemption.
    test "refuses one that has already been accepted" do
      {:ok, invitation} = Invitations.open(member(), %{"username" => "grace"})

      accepted =
        invitation |> Ecto.Changeset.change(accepted_at: DateTime.utc_now()) |> Repo.update!()

      assert {:error, :already_accepted} = Invitations.withdraw(accepted)
      assert Repo.aggregate(Invitation, :count) == 1
    end
  end
end
