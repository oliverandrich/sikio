# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.IdentityTest do
  @moduledoc """
  What an account is called here: a name, or an address.

  Ithibati binds the identifier field at compile time — `ithibati_account/0` expands to a literal
  field name — so the two modes cannot be two fields. They are one column holding two kinds of
  thing, and what tells them apart is the format. That makes the format the whole switch, which
  is why it is asked of one module and tested here rather than spelled out at each schema.
  """
  # async: false — the mode is application configuration and these set it.
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

    # A value nobody knows is a mistake in the configuration, and guessing which one was meant
    # would decide for an operator what their instance is.
    test "is refused when it is neither, and the message names the key" do
      as(:handle)

      assert_raise RuntimeError, ~r/account_identity/, &Identity.mode/0
    end

    # Compared by source: two regexes built from the same pattern are not `==`, because each
    # carries its own compiled form.
    test "carries the format that belongs to it" do
      assert Regex.source(Identity.format()) == Regex.source(Identifier.username_format())

      as(:email)

      assert Regex.source(Identity.format()) == Regex.source(Identifier.email_format())
    end
  end

  # An instance that addresses its accounts has to be able to reach them: the invitation is the
  # only way in, and in that mode it is an address. Configured without a mailer, it would be an
  # instance nobody can be invited to, and the first person to notice would be the operator with
  # a guest waiting.
  describe "asking for addresses without being able to send any" do
    # Both halves of the way out: the setting that asked for addresses, and the one that would
    # make them deliverable. An operator sets the variable, so that is what is named.
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

    # Names need no mailer. An invitation link is handed over however its sender likes.
    test "and names never need one" do
      assert Identity.verify!(false) == :ok
    end

    # The two are wired together where the application starts, and that wiring is the only place
    # either of them is asked. A test that called them separately would pass while the boot did
    # nothing.
    test "and the answer comes from the mailer at boot" do
      as(:email)

      assert_raise RuntimeError, ~r/MAIL_ENABLED/, fn ->
        Identity.verify!(Mailer.configured?())
      end

      TestConfig.put_env(:sikio, :mail_enabled, true)

      assert Identity.verify!(Mailer.configured?()) == :ok
    end
  end

  # Both schemas, because Ithibati refuses a pair that disagrees and this application declares the
  # identifier twice. A format enforced on one of them only is a form that accepts what the
  # ceremony then refuses.
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

    # Ithibati skips minting a token and asking the accounts table when the changeset is already
    # invalid, and carrying `:format` at `use` is what used to make it invalid in time. With the
    # format asked per instance instead, the shape has to be checked before any of that.
    test "and a refused invitation costs no token" do
      as(:email)

      changeset = Invitation.changeset(%Invitation{}, %{"username" => "ada"})

      refute changeset.valid?
      refute Map.has_key?(changeset.changes, :token)
      refute Map.has_key?(changeset.changes, :token_hash)
    end

    # Ectos default beside a name field is "has invalid format", which names the fault and not
    # the rule. The sentence follows the mode, because the two modes refuse for different reasons
    # and the person reading it is being asked to type something else.
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

    # Ithibati keeps doing its half whatever the format is.
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
