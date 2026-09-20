# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Identity do
  @moduledoc """
  What an account is called on this instance: a name, or an address.

  Ithibati binds the identifier field when it compiles. `ithibati_account/0` expands to a literal
  field name, and the option may not even be a module attribute, so two modes cannot be two
  fields. They are one column holding two kinds of thing, and the format is what tells them apart.

  `:format` is therefore left off at both schemas, where it would be fixed for good, and asked
  here instead, where an instance can answer it. Ithibati still requires the value, trims it,
  lowercases it and caps it at 254 graphemes; this adds the shape.

  The mode is chosen once, before the first account. Turning an instance that already has accounts
  from names to addresses would leave every identifier it holds failing the new format.
  """
  alias Ithibati.Schema.Identifier
  alias Sikio.Mailer

  @modes [:username, :email]

  @doc "Whether an account here is named or addressed."
  def mode do
    case Application.get_env(:sikio, :account_identity, :username) do
      mode when mode in @modes ->
        mode

      other ->
        raise """
        config :sikio, account_identity: #{inspect(other)}

        An account is named or addressed, so this is #{Enum.map_join(@modes, " or ", &inspect/1)}.
        """
    end
  end

  @doc "Whether an account here is addressed, which is also what makes an invitation deliverable."
  def email?, do: mode() == :email

  @doc "The shape an identifier has to have, which is the whole of what the two modes differ by."
  def format, do: if(email?(), do: Identifier.email_format(), else: Identifier.username_format())

  @doc "Whether a value already has the shape this instance asks for."
  def shaped?(value), do: Regex.match?(format(), value)

  @doc """
  Adds this instance's shape to a changeset that already carries an identifier.

  Both schemas ask for it, and they have to agree: a format enforced on the account but not on
  the invitation is a form that accepts what the ceremony then refuses. Written once so that
  agreeing is not something either of them has to remember.
  """
  def validate(changeset, field \\ :username),
    do: Ecto.Changeset.validate_format(changeset, field, format())

  @doc """
  The identifier these attributes carry, trimmed and lowercased, or `nil` for none.

  Normalised the way Ithibati would, so that asking about the shape before it builds anything
  asks about the same value it will later hold.
  """
  def given(%{"username" => value}) when is_binary(value), do: Identifier.normalize(value)
  def given(%{username: value}) when is_binary(value), do: Identifier.normalize(value)
  def given(_attrs), do: nil

  @doc """
  Answers `:ok`, or raises when the instance asks for something it cannot do.

  An instance that addresses its accounts has to be able to reach them: in that mode the
  invitation is an address, and an address nobody can send to is an instance nobody can join.
  Asked where an instance starts, so a configuration like that is a refusal to boot rather than
  an operator finding out with a guest waiting.

  Names need no mailer. An invitation link is handed over however its sender likes.
  """
  def verify! do
    if email?() and not Mailer.configured?() do
      raise """
      config :sikio, account_identity: :email

      An account here is an address, so an invitation has to be delivered to one, and nothing is
      configured to send it. Set MAIL_ENABLED and the SMTP variables beside it, or name accounts
      instead: config :sikio, account_identity: :username. See docs/operations.md.
      """
    end

    :ok
  end
end
