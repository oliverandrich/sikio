# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Invitations do
  @moduledoc """
  Creates, lists, fetches and withdraws invitations.

  Every member may invite and withdraw their own invitations. An administrator withdraws any.

  The table belongs to this application; the invariants and queries belong to Ithibati.
  `pending_query/0` returns the predicate `fetch/1` uses. `withdraw/2` rechecks acceptance
  inside its delete, so it cannot remove an invitation accepted concurrently. Local copies of
  these queries could drift from Ithibati's.
  """
  import Ecto.Query

  alias Ecto.Changeset
  alias Ithibati.Identity.Invitations
  alias Sikio.Accounts
  alias Sikio.Accounts.Invitation
  alias Sikio.Accounts.User
  alias Sikio.Identity
  alias Sikio.Repo

  @doc """
  Inserts an invitation with `inviter` as `invited_by_id`.

  The inviter is set with `put_change/3`, not cast from `attrs`. The invitations page passes form
  parameters through unchanged, so casting would let the form choose the inviter.

  Only the returned struct carries the plaintext token. The row stores its digest. A struct
  loaded later has no token.

  Addressed, the invitation binds the address it is sent to. Named, it is open: the invitee
  chooses the username.
  """
  def open(%User{} = inviter, attrs) do
    %Invitation{}
    |> Invitation.changeset(attrs, addressed: Identity.email?())
    |> Changeset.put_change(:invited_by_id, inviter.id)
    |> Repo.insert()
  end

  @doc """
  Returns invitations that are neither accepted nor expired, soonest expiry first.

  The list serves decisions about pending invitations, so the one closest to expiry comes first.

  `invited_by` is preloaded. It is `nil` for a row written before the column existed.
  """
  def pending do
    Invitations.pending_query()
    |> order_by([i], asc: i.expires_at)
    |> preload(:invited_by)
    |> Repo.all()
  end

  @doc """
  Returns the invitation with `id`, or `nil` when none matches or `id` does not cast.

  `id` comes from a form unvalidated. `Repo.get/2` raises `Ecto.Query.CastError` on a value the
  primary key type rejects, so `id` is cast first. The type is read from the schema, because the
  primary key type is configurable.
  """
  def get(id) do
    type = Invitation.__schema__(:type, :id)

    case Ecto.Type.cast(type, id) do
      {:ok, named} -> Repo.get(Invitation, named)
      :error -> nil
    end
  end

  @doc """
  Deletes an invitation that has not been accepted, for its inviter or an administrator. Its
  link stops working immediately.

  The administrator role is read from the database. Returns `{:ok, invitation}`,
  `{:error, :forbidden}` for another member, or `{:error, :already_accepted}` when it was accepted
  or deleted in the meantime. Acceptance and expiry are not modified.
  """
  def withdraw(%User{id: id}, %Invitation{invited_by_id: id} = invitation),
    do: Invitations.withdraw(invitation)

  # The role is read with the administrator rows locked, so a concurrent revocation waits.
  def withdraw(%User{} = account, invitation),
    do: Accounts.with_admin(account, fn _admins -> Invitations.withdraw(invitation) end)

  @doc """
  Returns whether `account` may take `invitation` back, by the struct's role, for showing the
  button. `withdraw/2` decides by the stored role.
  """
  def withdrawable?(%User{id: id, admin: admin}, %Invitation{invited_by_id: inviter}),
    do: admin or inviter == id
end
