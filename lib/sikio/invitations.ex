# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Invitations do
  @moduledoc """
  What is outstanding, who made it, and taking one back.

  Nobody can be removed from this instance once they are in. The only moment anybody can
  influence who joins is before a link is redeemed, which is exactly the moment that used to be
  invisible: the table was written and never read. Every member may invite and every member may
  withdraw, because dividing members into classes is the answer this application does not want.

  The table is this application's and the invariants are Ithibati's, so the queries come from
  there. `pending_query/0` hands over the predicate `fetch/1` uses, and `withdraw/1` rechecks the
  acceptance inside its delete, so a withdrawal cannot remove an invitation that is being
  redeemed at that moment. Writing either here would be a second opinion about when an invitation
  is still good, and the two would drift.
  """
  import Ecto.Query

  alias Ecto.Changeset
  alias Ithibati.Identity.Invitations
  alias Sikio.Accounts.Invitation
  alias Sikio.Accounts.User
  alias Sikio.Repo

  @doc """
  Writes an invitation and records who made it.

  The inviter is put on the changeset rather than cast from the attributes. Who is inviting is
  known to the caller and to nobody else, least of all to the form, and this page hands its
  parameters straight through.

  The plaintext token is on the returned struct and nowhere else: the row holds its digest, and
  anything read back later has an empty one.
  """
  def open(%User{} = inviter, attrs) do
    %Invitation{}
    |> Invitation.changeset(attrs)
    |> Changeset.put_change(:invited_by_id, inviter.id)
    |> Repo.insert()
  end

  @doc """
  Every invitation that is neither accepted nor run out, soonest to expire first.

  Ordered by expiry rather than by when it was made: the list is read to decide about what is
  about to happen, and the one closest to being used is the one worth seeing first.

  The inviter comes with it, and is `nil` for a row written before the column existed. That is a
  real answer, not a missing one.
  """
  def pending do
    Invitations.pending_query()
    |> order_by([i], asc: i.expires_at)
    |> preload(:invited_by)
    |> Repo.all()
  end

  @doc """
  One invitation by id, or `nil` for an id that names none.

  The id arrives from a form and nothing upstream says it is a number, so it is cast here rather
  than handed to `Repo.get/2`, which raises `Ecto.Query.CastError` on anything its primary key
  cannot hold. Asked of the schema rather than assumed: the key type is a setting, and a guess
  written here would be wrong the moment it changes.
  """
  def get(id) do
    type = Invitation.__schema__(:type, :id)

    case Ecto.Type.cast(type, id) do
      {:ok, named} -> Repo.get(Invitation, named)
      :error -> nil
    end
  end

  @doc """
  Takes back an invitation that has not been accepted, and its link stops working at once.

  Answers `{:error, :already_accepted}` for one that was redeemed in the meantime. Nothing here
  changes an acceptance or an expiry.
  """
  defdelegate withdraw(invitation), to: Invitations
end
