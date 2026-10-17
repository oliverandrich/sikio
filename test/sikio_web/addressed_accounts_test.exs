# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddressedAccountsTest do
  @moduledoc """
  Forms and messages in email mode compared with username mode.

  The `:account_identity` setting switches the identifier. Every form and message naming it must
  follow, or the form and the ceremony disagree. A mismatched input pattern fails only after the
  passkey prompt.
  """
  # async: false, because these tests change application configuration.
  use SikioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Identity
  alias Sikio.Repo
  alias Sikio.TestConfig
  alias SikioWeb.CeremonyMessages

  defp addressing, do: TestConfig.put_env(:sikio, :account_identity, :email)

  # Skips the setup code form, because only the claim form asks for the identifier.
  setup %{conn: conn}, do: %{conn: claiming_conn(conn)}

  test "the first account is asked for as an address", %{conn: conn} do
    addressing()

    {:ok, _view, html} = live(conn, ~p"/setup")

    assert html =~ ~s(type="email")
    refute html =~ "Username"
  end

  test "and as a name otherwise", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup")

    assert html =~ "Username"
    refute html =~ ~s(type="email")
  end

  # The invitation form prefixes the changeset message with the field label.
  # The message must not repeat the label. The assertion matches the full sentence,
  # because `=~ "address"` also passes when the label appears twice.
  test "the invitation refusal names the field once" do
    addressing()

    # The address comes first: the note is optional here.
    blank = refusal_for(%{"username" => "", "note" => ""})
    assert blank =~ "Email address can&#39;t be blank."
    refute blank =~ "Note can"

    assert refusal_for(%{"username" => "not-an-address"}) =~
             "Email address must look like grace@example.org."

    TestConfig.put_env(:sikio, :account_identity, :username)

    # Named, the form asks only for a note; the invitee chooses the name.
    assert refusal_for(%{"note" => " "}) =~ "Note can&#39;t be blank."
  end

  defp refusal_for(fields) do
    # The inviter's username must be valid in the current mode.
    inviter =
      if Identity.email?(), do: unique_username() <> "@example.org", else: unique_username()

    account = Repo.insert!(User.changeset(%User{}, %{username: inviter}))
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> Gate.log_in(account)

    {:ok, view, _html} = live(conn, ~p"/invitations")

    view |> form("#invitation-form", fields) |> render_submit()
  end

  # Ithibati's error codes name `username` in both modes. `CeremonyMessages` words them per mode.
  test "a refusal says what was actually wanted" do
    assert CeremonyMessages.message("invalid_username", nil) =~ "underscores"

    addressing()

    assert CeremonyMessages.message("invalid_username", nil) =~ "address"
    refute CeremonyMessages.message("invalid_username", nil) =~ "underscores"
  end

  test "and so does one about a name already taken" do
    assert CeremonyMessages.message("username_taken", nil) =~ "username"

    addressing()

    assert CeremonyMessages.message("username_taken", nil) =~ "address"
  end

  test "and one about arriving without any" do
    assert CeremonyMessages.message("username_required", nil) =~ "username"
    # The claim and an open invitation both ask for a name, so the sentence names neither.
    refute CeremonyMessages.message("username_required", nil) =~ "claim"

    addressing()

    assert CeremonyMessages.message("username_required", nil) =~ "address"
    refute CeremonyMessages.message("username_required", nil) =~ "claim"
  end
end
