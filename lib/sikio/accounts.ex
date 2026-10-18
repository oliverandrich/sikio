# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts do
  @moduledoc """
  The administrator role and what it allows: listing accounts, granting and revoking the role,
  and removing an account with its Ithibati sessions. The last administrator keeps the role.

  Each function takes the acting account first and reads its flag from the database, so a stale
  struct grants nothing. Ithibati owns sign-in; this module calls its public session API only.
  """
  import Ecto.Query

  alias Ithibati.Identity.Sessions
  alias Ithibati.Schema.Identifier
  alias Sikio.Accounts.User
  alias Sikio.Repo

  @doc """
  Lists every account by username for an administrator.

  Returns `{:error, :forbidden}` unless `admin` is one.
  """
  def list_accounts(%User{id: id}) do
    if Repo.exists?(from u in User, where: u.id == ^id and u.admin),
      do: {:ok, Repo.all(from u in User, order_by: u.username)},
      else: {:error, :forbidden}
  end

  @doc """
  Makes the account with `account_id` an administrator.

  Returns `{:error, :forbidden}` unless `admin` is one, and `{:error, :not_found}` for an
  unknown account.
  """
  def grant_admin(admin, account_id),
    do: as_admin(admin, fn _admins -> account_id |> account() |> set_admin(true) end)

  @doc """
  Takes the role from the account with `account_id`. An administrator may revoke it from
  themselves.

  Returns `{:error, :last_admin}` when no other administrator would remain, besides the errors
  of `grant_admin/2`.
  """
  def revoke_admin(admin, account_id) do
    as_admin(admin, fn admins ->
      case account(account_id) do
        %User{id: id} when admins == [id] -> {:error, :last_admin}
        account -> set_admin(account, false)
      end
    end)
  end

  @doc """
  Removes the account with `account_id` and everything it owns, with its sessions.

  The sessions are revoked in the same transaction, so none is created between revocation and
  deletion. Returns `{:ok, digests}` with the revoked sessions' digests, for
  `Ithibati.Web.Gate.disconnect_sessions/2` after the commit. An administrator cannot remove
  their own account here: `{:error, :self}`. Otherwise it returns the errors of `grant_admin/2`.
  """
  def remove_account(%User{id: id} = admin, account_id) do
    as_admin(admin, fn _admins ->
      # Locked, so a session that is signing in waits for the deletion instead of slipping past.
      case account(account_id, lock: true) do
        nil -> {:error, :not_found}
        %User{id: ^id} -> {:error, :self}
        account -> removed(account)
      end
    end)
  end

  defp removed(account) do
    digests = Sessions.revoke_all(account)
    with {:ok, _account} <- Repo.delete(account), do: {:ok, digests}
  end

  @doc """
  Makes the account named `identifier` an administrator, for the operator on the host.

  The identifier is a username, or an address in email mode, normalized as Ithibati stores it.
  It checks no acting account: running a release command already takes access to the host.
  """
  def grant_admin_as_operator(identifier) do
    User
    |> Repo.get_by(username: Identifier.normalize(identifier))
    |> set_admin(true)
  end

  # Every administrator row is locked first, in one statement and in id order, so concurrent
  # changes queue instead of deadlocking. The acting account must be among them.
  defp as_admin(%User{id: id}, fun) do
    Repo.transaction(fn ->
      admins =
        from(u in User, where: u.admin, select: u.id, order_by: u.id)
        |> Repo.for_update()
        |> Repo.all()

      result = if id in admins, do: fun.(admins), else: {:error, :forbidden}
      committed(result)
    end)
  end

  defp committed({:ok, account}), do: account
  defp committed({:error, reason}), do: Repo.rollback(reason)

  # An id from a form arrives as a string.
  defp account(account_id, opts \\ []) do
    case Ecto.Type.cast(:id, account_id) do
      {:ok, id} ->
        query = from(u in User, where: u.id == ^id)
        Repo.one(if opts[:lock], do: Repo.for_update(query), else: query)

      :error ->
        nil
    end
  end

  defp set_admin(nil, _admin), do: {:error, :not_found}

  defp set_admin(account, admin),
    do: account |> Ecto.Changeset.change(admin: admin) |> Repo.update()
end
