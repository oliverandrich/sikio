# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.AccountAddress do
  @moduledoc """
  Changes the address an account is identified by, in email mode.

  A request stores the new address beside the account and returns a token for the link.
  Only a confirmation by the same account writes the address, so the old one stays in force
  until then. Sign-in uses passkeys without an identifier, so neither address is needed to sign
  in, and sessions and passkeys stay as they are.

  A request expires after seven days, as an invitation does. A new request replaces the earlier
  one and its link.
  """
  import Ecto.Query

  alias Ecto.Changeset
  alias Ithibati.Identity.Invitations
  alias Sikio.Accounts.AddressRequest
  alias Sikio.Accounts.User
  alias Sikio.Identity
  alias Sikio.Repo

  @days 7

  @doc """
  Stores a request for `address` and returns `{:ok, request, token}`.

  Returns `{:error, changeset}` for an address the format rejects, `{:error, :unchanged}` for the
  account's own address, `{:error, :taken}` for another account's, `{:error, :invited}` for one an
  open invitation names, and `{:error, :username_mode}` outside email mode.
  """
  def request(%User{} = account, address) do
    with :ok <- email_mode(),
         {:ok, address} <- valid(account, address),
         :ok <- available(account, address) do
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

      # One statement replaces an earlier request, so two submits at once cannot collide.
      {:ok, request} =
        Repo.insert(
          %AddressRequest{
            user_id: account.id,
            address: address,
            token_digest: digest(token),
            expires_at: DateTime.add(DateTime.utc_now(), @days, :day)
          },
          on_conflict: {:replace, [:address, :token_digest, :expires_at, :inserted_at]},
          conflict_target: :user_id,
          returning: true
        )

      {:ok, request, token}
    end
  end

  @doc "Returns the account's current request that `token` belongs to, or nil."
  def requested(%User{id: id}, token) when is_binary(token),
    do: Repo.one(requested_query(id, token))

  @doc "Returns the account's request that has not expired, or nil."
  def pending(%User{id: id}),
    do: Repo.one(from r in AddressRequest, where: r.user_id == ^id, where: ^current())

  @doc """
  Writes the requested address into `account` when `token` belongs to its current request.

  Returns `{:ok, account, old_address}`, with the address the stored account had. Returns
  `{:error, :not_found}` for a token of another account, an expired request or an unknown token.
  Returns `{:error, :taken}` or `{:error, :invited}` when another account or an open invitation
  took the address meanwhile, and `{:error, changeset}` when the address fails validation.
  """
  def confirm(%User{id: id}, token) when is_binary(token) do
    Repo.transaction(fn ->
      # The account is read again and locked, since the caller's struct may be stale.
      with %AddressRequest{} = request <- Repo.one(Repo.for_update(requested_query(id, token))),
           %User{} = account <- Repo.one(Repo.for_update(from u in User, where: u.id == ^id)),
           :ok <- available(account, request.address),
           {:ok, changed} <- account |> User.changeset(%{username: request.address}) |> update() do
        Repo.delete!(request)
        {changed, account.username}
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {changed, old}} -> {:ok, changed, old}
      error -> error
    end
  end

  @doc "Deletes the account's request, if any. Its link then confirms nothing."
  def withdraw(%User{id: id}) do
    Repo.delete_all(from r in AddressRequest, where: r.user_id == ^id)
    :ok
  end

  @doc "Deletes expired requests and returns how many."
  def delete_expired do
    {count, _} =
      Repo.delete_all(from r in AddressRequest, where: r.expires_at <= ^DateTime.utc_now())

    count
  end

  defp email_mode, do: if(Identity.email?(), do: :ok, else: {:error, :username_mode})

  # The account changeset normalizes and checks the format, as for a new account.
  defp valid(account, address) do
    changeset = User.changeset(account, %{username: address})

    cond do
      not changeset.valid? -> {:error, changeset}
      Changeset.get_field(changeset, :username) == account.username -> {:error, :unchanged}
      true -> {:ok, Changeset.get_field(changeset, :username)}
    end
  end

  # An open invitation for the address would fail once accepted, so the request does instead.
  defp available(account, address) do
    cond do
      Repo.exists?(from u in User, where: u.username == ^address and u.id != ^account.id) ->
        {:error, :taken}

      Repo.exists?(from i in Invitations.pending_query(), where: i.username == ^address) ->
        {:error, :invited}

      true ->
        :ok
    end
  end

  defp update(changeset) do
    case Repo.update(changeset) do
      {:ok, account} ->
        {:ok, account}

      {:error, changeset} ->
        if Ithibati.Schema.User.identifier_taken?(changeset),
          do: {:error, :taken},
          else: {:error, changeset}
    end
  end

  defp requested_query(id, token),
    do:
      from(r in AddressRequest,
        where: r.user_id == ^id and r.token_digest == ^digest(token),
        where: ^current()
      )

  defp current, do: dynamic([r], r.expires_at > ^DateTime.utc_now())

  defp digest(token), do: :crypto.hash(:sha256, token)
end
