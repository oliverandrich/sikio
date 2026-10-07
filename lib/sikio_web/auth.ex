# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Auth do
  @moduledoc """
  Implements the `Ithibati.Web.Handler` callbacks for Sikio.

  Registration requires an invitation, except for the first account on an unclaimed instance.
  `registration_subject/2` checks both before a challenge is issued.
  A refusal there starts no ceremony.
  An unknown token returns `:invitation_unknown`; a missing token returns `:invitation_required`.
  """
  @behaviour Ithibati.Web.Handler

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn, only: [get_session: 2, put_session: 3]

  require Logger

  alias Ecto.Multi
  alias Ithibati.Identity.Grant
  alias Ithibati.Identity.Instance
  alias Ithibati.Identity.Invitations
  alias Ithibati.Identity.Passkeys
  alias Ithibati.Schema
  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Repo
  alias SikioWeb.Reauth

  @impl true
  def registration_subject(conn, %{"intent" => "add_passkey"}) do
    case conn.assigns[:current_account] do
      %User{} = account ->
        if Reauth.confirmed?(conn), do: {:ok, account}, else: {:error, :reauthentication_required}

      _ ->
        {:error, :authentication_required}
    end
  end

  def registration_subject(conn, params) do
    if Instance.needs_setup?(),
      do: claiming(conn, params),
      else: invited(params["token"])
  end

  # Checks the setup authorization before a first-account ceremony starts.
  # The check runs here as well as on the page, because a request can reach the endpoint directly.
  defp claiming(conn, params) do
    if claim_open?(setup_authorization(conn)),
      do: first_account(params),
      else: {:error, :setup_authorization_required}
  end

  @doc """
  Returns whether the given setup authorization permits creating the first account.

  `registration_subject/2` and the setup page both call this function.
  A single definition keeps the page from offering a form the ceremony refuses.
  """
  def claim_open?(authorization), do: Instance.authorized?(authorization)

  # The session stores the authorization proof, never the setup code.
  # The proof carries an expiry; `Instance.authorized?/1` checks it.
  defp setup_authorization(conn), do: get_session(conn, :setup_authorization)

  # The username comes from the invitation, not from the request.
  # `Invitations.accept/2` also rejects a mismatched username inside the transaction.
  defp invited(token) when is_binary(token) do
    case Invitations.fetch(token) do
      nil -> {:error, :invitation_unknown}
      invitation -> {:ok, invitation.username}
    end
  end

  defp invited(_missing), do: {:error, :invitation_required}

  # Validates the username before a challenge is issued.
  # A later refusal would leave an authenticator credential for an account that never exists.
  # The changeset validates the format, so no second pattern exists.
  # Returns the normalized username, so the passkey dialog shows the stored value.
  defp first_account(%{"username" => username}) do
    %User{}
    |> User.changeset(%{"username" => username})
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, account} -> {:ok, account.username}
      {:error, _changeset} -> {:error, :invalid_username}
    end
  end

  defp first_account(_params), do: {:error, :username_required}

  @impl true
  def register(conn, key_attrs, %User{id: id} = account, params) do
    case conn.assigns[:current_account] do
      %User{id: ^id} ->
        with true <- Reauth.confirmed?(conn),
             {:ok, _key} <- Passkeys.add_key(account, Map.put(key_attrs, :label, params["label"])) do
          {:ok, json(conn, %{redirect: "/account/passkeys"})}
        else
          false -> {:error, :reauthentication_required}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :authentication_required}
    end
  end

  def register(conn, key_attrs, username, params) do
    conn
    |> acceptance(username, params["token"], key_attrs)
    |> Repo.transaction()
    |> case do
      {:ok, %{account: account, recovery_codes: codes} = changes} ->
        event =
          if Map.has_key?(changes, :bootstrap),
            do: "instance claimed",
            else: "invitation accepted"

        Logger.info(event, account_id: account.id)

        {:ok,
         conn
         |> Gate.log_in(account)
         |> put_session(:recovery_codes, codes)
         |> json(%{redirect: "/recovery-codes"})}

      {:error, :account, %Ecto.Changeset{} = changeset, _changes} ->
        {:error, account_error(changeset)}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Chooses the claim or invitation transaction with the same check as `registration_subject/2`.
  # The choice ignores `params`, because the client resends the whole body at this step.
  defp acceptance(conn, username, token, key_attrs) do
    if Instance.needs_setup?(),
      do: claim_instance(username, key_attrs, setup_authorization(conn)),
      else: accept_invitation(Invitations.fetch(token), username, key_attrs)
  end

  # The invitation is fetched again, because the challenge carries only the username.
  # A token for a different username is refused here.
  # `accept/2` checks again inside the transaction, which closes the race.
  defp accept_invitation(%{username: username} = invitation, username, key_attrs) do
    Multi.new()
    |> Multi.insert(:account, User.changeset(%User{}, Invitations.account_attrs(invitation)))
    |> Invitations.accept(invitation)
    |> Grant.with_key_and_codes(key_attrs)
  end

  # Accepted, expired, unknown and mismatched invitations return the same error.
  # The response does not reveal whether a token ever existed.
  defp accept_invitation(_other, _username, _key_attrs),
    do: Multi.error(Multi.new(), :invitation, :invitation_unknown)

  # Creates the first account without an invitation. `Instance.claim/2` refuses a second claim.
  # The claim step runs before the grant, as `accept/2` does above.
  # A failed transaction then generates no recovery codes.
  # Generated codes would appear in plaintext in the returned `changes_so_far`.
  defp claim_instance(username, key_attrs, authorization) do
    Multi.new()
    |> Multi.insert(:account, User.changeset(%User{}, %{"username" => username}))
    |> Instance.claim(authorization: authorization)
    |> Grant.with_key_and_codes(key_attrs)
  end

  # A taken username comes from the unique index; an invalid one comes from format validation.
  # Only the index detects concurrent registrations of the same name.
  # Ithibati declares the index, so `identifier_taken?/1` identifies the constraint.
  defp account_error(changeset) do
    if Schema.User.identifier_taken?(changeset), do: :username_taken, else: :invalid_username
  end

  @impl true
  def authenticate(conn, account) do
    if Reauth.pending?(conn),
      do: Reauth.complete(conn, account),
      else: {:ok, conn |> signed_in(account) |> json(%{redirect: "/"})}
  end

  defp signed_in(conn, account) do
    Logger.info("signed in", account_id: account.id)
    Gate.log_in(conn, account)
  end

  @impl true
  def recovered(conn, account, fresh) do
    cond do
      Reauth.pending?(conn) ->
        Reauth.complete(conn, account, fresh)

      is_nil(fresh) ->
        authenticate(conn, account)

      true ->
        {:ok,
         conn
         |> signed_in(account)
         |> put_session(:recovery_codes, fresh)
         |> json(%{redirect: "/recovery-codes"})}
    end
  end
end
