# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Accounts do
  @moduledoc """
  The administrator role. An administrator grants and revokes it; the last one keeps it.

  `grant_admin/2` and `revoke_admin/2` take the acting account first and read its flag from the
  database, so a stale struct grants nothing. Ithibati owns sign-in; this module owns only the
  role.
  """
  import Ecto.Query

  alias Ithibati.Schema.Identifier
  alias Sikio.Accounts.User
  alias Sikio.Repo

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
  defp account(account_id) do
    case Ecto.Type.cast(:id, account_id) do
      {:ok, id} -> Repo.get(User, id)
      :error -> nil
    end
  end

  defp set_admin(nil, _admin), do: {:error, :not_found}

  defp set_admin(account, admin),
    do: account |> Ecto.Changeset.change(admin: admin) |> Repo.update()
end
