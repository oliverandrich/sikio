# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Identity do
  @moduledoc """
  The account identifier mode of this instance: username or email address.

  Ithibati binds the identifier field at compile time. `ithibati_account/0` expands to a literal
  field name, and `identifier:` must be a literal atom, not a module attribute. So both modes
  share one column, and the format distinguishes them.

  A literal `:format` in either schema would be fixed at compile time. Both schemas pass
  `{Sikio.Identity, :format}` instead, and Ithibati calls it on every changeset. The changeset
  trims, lowercases and requires the value, applies the returned regex and caps it at 254
  graphemes. An invalid invitation changeset skips token generation and the accounts lookup.

  Choose the mode before the first account exists. Switching from usernames to addresses would
  make every existing identifier fail the new format.
  """
  alias Ithibati.Schema.Identifier

  @modes [:username, :email]

  @doc "Returns `:username` or `:email` from `:account_identity`. Raises for any other value."
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

  @doc "Returns whether accounts use email addresses. Only then can an invitation be mailed."
  def email?, do: mode() == :email

  @doc """
  Returns the identifier regex for the current mode. It is the only difference between modes.

  Both schemas pass `format: {Sikio.Identity, :format}` instead of a literal, so Ithibati calls
  this per changeset.
  """
  def format, do: if(email?(), do: Identifier.email_format(), else: Identifier.username_format())

  @doc """
  Returns the format error message for the current mode.

  Ecto's default, "has invalid format", names the fault, not the rule. This message states the
  rule, so the user knows what to enter.

  The message is a sentence fragment. The form shows the field label before it, and the
  invitation form names the field itself. A message that repeated the field would read
  "Email address must be an email address."
  """
  def format_message do
    if email?(),
      do: "must look like grace@example.org",
      else: "must be 1-30 lowercase letters, numbers or underscores"
  end

  @doc """
  Returns `:ok`, or raises when email mode has no mail delivery configured.

  In email mode an invitation is mailed to an address. Without delivery, nobody could join.
  `Sikio.Application` calls this at start, so the misconfiguration stops the boot.

  `deliverable?` comes from `Sikio.Mailer` as an argument. Both schemas name this module in their
  `use` options, which resolve at compile time. Any module this one calls would become a
  compile-time dependency of both schemas. `Sikio.Application` passes the value in.

  Username mode needs no mailer. The inviter shares the invitation link by any means.
  """
  def verify!(deliverable?) do
    if email?() and not deliverable? do
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
