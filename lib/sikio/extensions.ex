# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Extensions do
  @moduledoc """
  Connects browser extensions to an account with an authorization code and PKCE (RFC 7636, S256).

  The signed-in account confirms on `/extension/connect`. `authorize/2` issues a one-time code
  for the extension's redirect URI and challenge. The extension exchanges it with its verifier
  for a token in `exchange/3`. The code serves once, for a minute, and only with both. A token
  serves the extension API until the account disconnects it.

  Only an extension's own redirect URI is accepted: Firefox's `extensions.allizom.org` and
  Chrome's `chromiumapp.org`. Any other address would receive the code instead.
  """
  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Extensions.Grant
  alias Sikio.Extensions.Token
  alias Sikio.Repo

  @code_seconds 60

  # `identity.getRedirectURL/1` returns these hosts, with an optional path.
  @redirect_uris [
    ~r"\Ahttps://[0-9a-f]{40}\.extensions\.allizom\.org/[A-Za-z0-9_/-]*\z",
    ~r"\Ahttps://[a-p]{32}\.chromiumapp\.org/[A-Za-z0-9_/-]*\z"
  ]

  # The base64url SHA-256 digest of a verifier, without padding.
  @challenge ~r/\A[A-Za-z0-9_-]{43}\z/

  @last_use_seconds 3600

  @doc "Returns whether `challenge` has the form of an S256 code challenge."
  def challenge?(challenge) when is_binary(challenge), do: Regex.match?(@challenge, challenge)
  def challenge?(_challenge), do: false

  @doc "Returns whether `uri` is a browser extension's redirect URI."
  def redirect_uri?(uri) when is_binary(uri),
    do: Enum.any?(@redirect_uris, &Regex.match?(&1, uri))

  def redirect_uri?(_uri), do: false

  @doc """
  Issues a one-time code for `account` and returns `{:ok, code}`.

  `params` carries `redirect_uri`, `code_challenge` and `client`, the extension's name for
  itself. Returns `{:error, :redirect_uri}` or `{:error, :code_challenge}` for a value it
  cannot accept.
  """
  def authorize(%User{id: id}, params) do
    cond do
      not redirect_uri?(params["redirect_uri"]) ->
        {:error, :redirect_uri}

      not challenge?(params["code_challenge"]) ->
        {:error, :code_challenge}

      true ->
        code = secret()

        Repo.insert!(%Grant{
          user_id: id,
          code_digest: digest(code),
          code_challenge: params["code_challenge"],
          redirect_uri: params["redirect_uri"],
          label: label(params["client"]),
          expires_at: DateTime.add(DateTime.utc_now(), @code_seconds)
        })

        {:ok, code}
    end
  end

  @doc """
  Exchanges a code and its verifier for a token and returns `{:ok, token}`.

  The code is deleted on any attempt, so a wrong verifier cannot be retried.
  Returns `{:error, :invalid}` for an unknown, used or expired code, another redirect URI or
  a verifier that does not match the challenge.
  """
  def exchange(code, verifier, redirect_uri)
      when is_binary(code) and is_binary(verifier) and is_binary(redirect_uri) do
    # The delete decides which of two concurrent exchanges gets the code. It commits on a
    # failed check as well, so a code serves one attempt only.
    {:ok, result} =
      Repo.transaction(fn ->
        with %Grant{} = grant <- Repo.one(from g in Grant, where: g.code_digest == ^digest(code)),
             {1, _} <- Repo.delete_all(from g in Grant, where: g.id == ^grant.id),
             true <- DateTime.after?(grant.expires_at, DateTime.utc_now()),
             true <- grant.redirect_uri == redirect_uri,
             true <- Plug.Crypto.secure_compare(challenge(verifier), grant.code_challenge) do
          token = secret()

          Repo.insert!(%Token{
            user_id: grant.user_id,
            token_digest: digest(token),
            label: grant.label
          })

          {:ok, token}
        else
          _ -> {:error, :invalid}
        end
      end)

    result
  end

  def exchange(_code, _verifier, _redirect_uri), do: {:error, :invalid}

  @doc """
  Returns `{:ok, account}` for a token of a connected extension, else `:error`.

  The last use is written at most once an hour, since every request authenticates.
  """
  def authenticate(token) when is_binary(token) do
    query =
      from t in Token,
        where: t.token_digest == ^digest(token),
        join: u in assoc(t, :user),
        select: {t, u}

    case Repo.one(query) do
      {connected, account} ->
        used(connected)
        {:ok, account}

      nil ->
        :error
    end
  end

  def authenticate(_token), do: :error

  defp used(%Token{last_used_at: at} = connected) do
    now = DateTime.utc_now()

    if is_nil(at) or DateTime.diff(now, at) >= @last_use_seconds,
      do:
        Repo.update_all(from(t in Token, where: t.id == ^connected.id), set: [last_used_at: now])
  end

  @doc "Lists the account's connected extensions, the most recent first."
  def list(%User{id: id}),
    do:
      Repo.all(
        from t in Token, where: t.user_id == ^id, order_by: [desc: t.inserted_at, desc: t.id]
      )

  @doc "Disconnects one of the account's extensions. Returns `{:error, :not_found}` otherwise."
  def revoke(%User{id: user_id}, id) do
    with {:ok, id} <- Ecto.Type.cast(:id, id),
         {1, _} <- Repo.delete_all(from t in Token, where: t.id == ^id and t.user_id == ^user_id) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Deletes expired codes and returns how many."
  def delete_expired do
    {count, _} = Repo.delete_all(from g in Grant, where: g.expires_at <= ^DateTime.utc_now())
    count
  end

  @doc "Returns the name an extension is listed by: its own, trimmed and capped, or a default."
  def label(client) when is_binary(client) do
    case client |> String.trim() |> String.slice(0, 100) do
      "" -> label(nil)
      name -> name
    end
  end

  def label(_client), do: "Browser extension"

  defp challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp secret, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

  defp digest(value), do: :crypto.hash(:sha256, value)
end
