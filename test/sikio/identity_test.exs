# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.IdentityTest do
  @moduledoc """
  Tests the account identifier mode: username or email address.

  Ithibati binds the identifier field at compile time. `ithibati_account/0` expands to a literal
  field name, so both modes share one column. Only the validation format differs.
  `Sikio.Identity` provides that format to both schemas.
  """
  # Not async: these tests set the mode in application env.
  use Sikio.DataCase, async: false

  alias Ithibati.Schema.Identifier
  alias Sikio.Accounts.Invitation
  alias Sikio.Accounts.User
  alias Sikio.Identity
  alias Sikio.Mailer
  alias Sikio.TestConfig

  defp as(mode), do: TestConfig.put_env(:sikio, :account_identity, mode)

  describe "the mode" do
    test "is a name unless something says otherwise" do
      assert Identity.mode() == :username
      refute Identity.email?()
    end

    test "is an address when that is what was configured" do
      as(:email)

      assert Identity.mode() == :email
      assert Identity.email?()
    end

    # An unknown value is a configuration error. Falling back to a default would hide it.
    test "is refused when it is neither, and the message names the key" do
      as(:handle)

      assert_raise RuntimeError, ~r/account_identity/, &Identity.mode/0
    end

    # Compared by `Regex.source/1`. Two regexes from the same pattern may differ in their compiled
    # form, so `==` fails.
    test "carries the format that belongs to it" do
      assert Regex.source(Identity.format()) == Regex.source(Identifier.username_format())

      as(:email)

      assert Regex.source(Identity.format()) == Regex.source(Identifier.email_format())
    end
  end

  # In email mode, invitations are sent by mail. Without a mailer, nobody could be invited.
  describe "asking for addresses without being able to send any" do
    # The message names both fixes: `account_identity` and the `MAIL_ENABLED` variable.
    test "is refused, and the message names both ways out" do
      as(:email)

      message = assert_raise(RuntimeError, fn -> Identity.verify!(false) end).message

      assert message =~ "account_identity"
      assert message =~ "MAIL_ENABLED"
    end

    test "is fine once mail is configured" do
      as(:email)

      assert Identity.verify!(true) == :ok
    end

    # Username mode needs no mailer. The inviter shares the link directly.
    test "and names never need one" do
      assert Identity.verify!(false) == :ok
    end

    # `Sikio.Application` calls `Identity.verify!(Mailer.configured?())` at start. This test
    # repeats that call with `:mail_enabled` unset and set. It does not start the application.
    test "and the answer comes from the mailer at boot" do
      as(:email)

      assert_raise RuntimeError, ~r/MAIL_ENABLED/, fn ->
        Identity.verify!(Mailer.configured?())
      end

      TestConfig.put_env(:sikio, :mail_enabled, true)

      assert Identity.verify!(Mailer.configured?()) == :ok
    end
  end

  # Both schemas declare the identifier, and Ithibati rejects a mismatch between them.
  # A format on only one schema would let the form accept what registration rejects.
  describe "what an account and an invitation accept" do
    test "a name in name mode, and not an address" do
      assert valid?(User, "ada")
      refute valid?(User, "ada@example.org")
      assert valid?(Invitation, "ada")
      refute valid?(Invitation, "ada@example.org")
    end

    test "an address in address mode, and not a name" do
      as(:email)

      assert valid?(User, "ada@example.org")
      refute valid?(User, "ada")
      assert valid?(Invitation, "ada@example.org")
      refute valid?(Invitation, "ada")
    end

    # Ithibati skips token generation and the accounts lookup for an invalid changeset.
    # The runtime format must therefore be validated before Ithibati's changeset steps.
    test "and a refused invitation costs no token" do
      as(:email)

      changeset = Invitation.changeset(%Invitation{}, %{"username" => "ada"})

      refute changeset.valid?
      refute Map.has_key?(changeset.changes, :token)
      refute Map.has_key?(changeset.changes, :token_hash)
    end

    # Ecto's default message is "has invalid format", which does not state the rule.
    # The message depends on the mode and describes the expected input.
    test "and the refusal says what this instance asks for" do
      assert refusal(User, "Ada Lovelace") == [
               "must be 1-30 lowercase letters, numbers or underscores"
             ]

      assert refusal(Invitation, "Ada Lovelace") ==
               ["must be 1-30 lowercase letters, numbers or underscores"]

      as(:email)

      assert refusal(User, "ada") == ["must look like grace@example.org"]
      assert refusal(Invitation, "ada") == ["must look like grace@example.org"]
    end

    # Ithibati's required-field validation applies in every mode.
    test "and neither accepts nothing at all" do
      refute valid?(User, "")
      refute valid?(Invitation, "")
    end
  end

  defp valid?(User, value),
    do: %User{} |> User.changeset(%{"username" => value}) |> Map.get(:valid?)

  defp valid?(Invitation, value),
    do: %Invitation{} |> Invitation.changeset(%{"username" => value}) |> Map.get(:valid?)

  defp refusal(User, value),
    do: %User{} |> User.changeset(%{"username" => value}) |> errors_on() |> Map.get(:username)

  defp refusal(Invitation, value) do
    %Invitation{}
    |> Invitation.changeset(%{"username" => value})
    |> errors_on()
    |> Map.get(:username)
  end
end
