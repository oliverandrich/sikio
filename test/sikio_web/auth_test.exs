# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AuthTest do
  @moduledoc """
  Tests the registration callbacks of `SikioWeb.Auth` directly.

  Ithibati tests the WebAuthn ceremony itself. These tests cover who may start a registration
  and which account it creates. The callbacks are called as `Ithibati.Web.PasskeyController`
  calls them.
  """
  use Sikio.DataCase, async: true

  alias Ithibati.Identity.Instance
  alias Ithibati.Identity.Invitations
  alias Sikio.Accounts.Invitation
  alias Sikio.Accounts.User
  alias SikioWeb.Auth

  # The two keys of the `Ithibati.Identity.Passkeys.verify_registration/2` result that
  # `Grant.with_key_and_codes/3` reads. Random bytes suffice, since no test covers the ceremony.
  defp key_attrs do
    %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)}
  end

  # `Gate.log_in/2` renews the session and raises unless it was fetched.
  # `claiming_conn/0` also carries the setup code proof that a first account requires.
  defp conn, do: claiming_conn()

  defp claim_instance(username) do
    {:ok, _conn} = Auth.register(conn(), key_attrs(), username, %{})

    Repo.get_by!(User, username: username)
  end

  defp invite(username, opts \\ []) do
    %Invitation{}
    |> Invitation.changeset(%{"username" => username}, opts)
    |> Repo.insert!()
  end

  describe "the first account" do
    test "arrives without an invitation, and claims the instance doing it" do
      assert {:ok, "first_one"} = Auth.registration_subject(conn(), %{"username" => "first_one"})

      assert {:ok, _conn} = Auth.register(conn(), key_attrs(), "first_one", %{})

      assert Repo.get_by(User, username: "first_one")
      refute Instance.needs_setup?()
    end

    test "is the only one: the next person needs an invitation" do
      claim_instance("first_one")

      assert {:error, :invitation_required} =
               Auth.registration_subject(conn(), %{"username" => "second"})
    end

    test "is refused without a username, rather than minting a challenge for nobody" do
      assert {:error, :username_required} = Auth.registration_subject(conn(), %{})
    end

    # Approving an invalid name here would open the passkey prompt and store a credential
    # on the authenticator before the refusal.
    test "is refused when the name is one the schema could never store" do
      for value <- ["Alice Smith!", "alice.smith", String.duplicate("a", 31), ""] do
        assert {:error, :invalid_username} =
                 Auth.registration_subject(conn(), %{"username" => value}),
               "approved #{inspect(value)}"
      end
    end

    test "and the name it approves is the one that will be stored" do
      assert {:ok, "ada"} = Auth.registration_subject(conn(), %{"username" => "  Ada  "})
    end
  end

  describe "an invitation" do
    setup do
      claim_instance("first_one")

      %{invitation: invite("invitee")}
    end

    test "opens a registration for the name it was addressed to", ctx do
      assert {:ok, "invitee"} =
               Auth.registration_subject(conn(), %{"token" => ctx.invitation.token})
    end

    test "creates that account and is spent in the same breath", ctx do
      assert {:ok, _conn} =
               Auth.register(conn(), key_attrs(), "invitee", %{"token" => ctx.invitation.token})

      assert Repo.get_by(User, username: "invitee")
      assert Repo.get!(Invitation, ctx.invitation.id).accepted_at
    end

    test "cannot be spent twice", ctx do
      assert {:ok, _conn} =
               Auth.register(conn(), key_attrs(), "invitee", %{"token" => ctx.invitation.token})

      assert {:error, :invitation_unknown} =
               Auth.register(conn(), key_attrs(), "invitee", %{"token" => ctx.invitation.token})
    end
  end

  # Used, expired and unknown tokens return the same error.
  # Distinct errors would reveal which guessed tokens once existed.
  describe "a token that opens nothing" do
    setup do
      claim_instance("first_one")

      :ok
    end

    test "is refused when nobody ever held it" do
      assert {:error, :invitation_unknown} =
               Auth.registration_subject(conn(), %{"token" => "not-a-token"})
    end

    test "is refused when it was already accepted" do
      invitation = invite("invitee")
      {:ok, _conn} = Auth.register(conn(), key_attrs(), "invitee", %{"token" => invitation.token})

      assert {:error, :invitation_unknown} =
               Auth.registration_subject(conn(), %{"token" => invitation.token})
    end

    test "is refused when it has expired" do
      invitation = invite("invitee", days: -1)

      assert {:error, :invitation_unknown} =
               Auth.registration_subject(conn(), %{"token" => invitation.token})
    end

    test "is refused when there is no token at all" do
      assert {:error, :invitation_required} = Auth.registration_subject(conn(), %{})
    end
  end

  # The browser resends the full body at the verify step, so that token is client input.
  # The identifier in the challenge is set by the server. When they disagree, registration fails.
  # The invitation named by the token stays open.
  test "the invitation accepted is the one the challenge approved, not the one the second request names" do
    claim_instance("first_one")
    invited = unique_username("invited")
    other = invite(unique_username("other"))
    _ = invite(invited)

    assert {:error, :invitation_unknown} =
             Auth.register(conn(), key_attrs(), invited, %{"token" => other.token})

    refute Repo.get_by(User, username: invited)
    refute Repo.get_by(User, username: other.username)
    assert Invitations.fetch(other.token)
  end

  # `register/4` takes the subject from the session, not the request, so it is checked again.
  # `:username_taken` would be false for a name nobody holds.
  # The two errors come from different checks; only the unique constraint means taken.
  test "a subject the schema refuses is answered as malformed, not as taken" do
    assert {:error, :invalid_username} = Auth.register(conn(), key_attrs(), "Not A Name!", %{})
  end

  # Two invitations may name the same username, and the first acceptance wins.
  # The second must return `:username_taken`, not `verification_failed`.
  # `verification_failed` is the controller's fallback for a changeset error.
  test "a name somebody already has is named as such, not collapsed into a generic failure" do
    claim_instance("first_one")
    first = invite("twin")
    second = invite("twin")

    assert {:ok, _conn} = Auth.register(conn(), key_attrs(), "twin", %{"token" => first.token})

    assert {:error, :username_taken} =
             Auth.register(conn(), key_attrs(), "twin", %{"token" => second.token})
  end

  test "a registration with no invitation is refused even if one was approved earlier" do
    claim_instance("first_one")
    invitation = invite("invitee")

    assert {:ok, "invitee"} = Auth.registration_subject(conn(), %{"token" => invitation.token})

    assert {:error, :invitation_unknown} = Auth.register(conn(), key_attrs(), "invitee", %{})

    refute Repo.get_by(User, username: "invitee")
  end
end
