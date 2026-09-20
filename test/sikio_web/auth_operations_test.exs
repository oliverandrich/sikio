# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AuthOperationsTest do
  use Sikio.DataCase

  alias Ithibati.Challenge
  alias Ithibati.Identity.Sessions
  alias Ithibati.Session
  alias Sikio.Accounts.Invitation
  alias Sikio.Accounts.User
  alias Sikio.AuthCleanup

  test "cleanup removes only expired records and is idempotent" do
    account = Repo.insert!(User.changeset(%User{}, %{username: "ada"}))
    active_token = Sessions.generate_session_token(account)

    expired =
      Repo.insert!(%Session{
        user_id: account.id,
        token_hash: :crypto.strong_rand_bytes(32),
        inserted_at: DateTime.add(DateTime.utc_now(), -61, :day)
      })

    stale =
      Repo.insert!(%Challenge{
        token_hash: :crypto.strong_rand_bytes(32),
        expires_at: DateTime.add(DateTime.utc_now(), -60)
      })

    active =
      Repo.insert!(%Challenge{
        token_hash: :crypto.strong_rand_bytes(32),
        expires_at: DateTime.add(DateTime.utc_now(), 60)
      })

    old_invite =
      Repo.insert!(Invitation.changeset(%Invitation{}, %{username: "expired"}, days: -1))

    good_invite = Repo.insert!(Invitation.changeset(%Invitation{}, %{username: "active"}))

    assert AuthCleanup.run() == %{sessions: 1, challenges: 1, invitations: 1}
    refute Repo.get(Session, expired.id)
    refute Repo.get(Challenge, stale.token_hash)
    refute Repo.get(Invitation, old_invite.id)
    assert Repo.get(Challenge, active.token_hash)
    assert Repo.get(Invitation, good_invite.id)
    assert Sessions.get_user_by_session_token(active_token)
    assert AuthCleanup.run() == %{sessions: 0, challenges: 0, invitations: 0}
  end
end
