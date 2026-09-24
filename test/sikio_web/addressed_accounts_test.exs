# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AddressedAccountsTest do
  @moduledoc """
  What the screens ask for, and say, when an account is an address rather than a name.

  The rule is one setting deep, so every surface that spells "username" has to follow it or the
  interface asks for one thing and the ceremony refuses another. A form offering a pattern no
  address can match is the expensive version of that: it is refused after the passkey dialogue.
  """
  # async: false — the mode is application configuration and these set it.
  use SikioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Identity
  alias Sikio.Repo
  alias Sikio.TestConfig
  alias SikioWeb.CeremonyMessages

  defp addressing, do: TestConfig.put_env(:sikio, :account_identity, :email)

  # Past the operator's code, because the claim form is what asks for the identifier and the code
  # form stands in front of it.
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

  # The invitation form puts the field's name in front of whatever the changeset said, so the
  # sentence the shape is refused with has to read as the second half of one and not as a whole
  # one of its own. Written out rather than matched loosely: the fault this catches is the field
  # named twice, and a `=~ "address"` passes straight through it.
  test "the invitation refusal names the field once" do
    addressing()

    assert refusal_for("not-an-address") =~ "Email address must look like grace@example.org."

    TestConfig.put_env(:sikio, :account_identity, :username)

    assert refusal_for("not a name") =~
             "Username must be 1-30 lowercase letters, numbers or underscores."
  end

  defp refusal_for(value) do
    # The inviter has to satisfy the mode as well: an account is an address here or a name there,
    # and the same fixture cannot be both.
    inviter = if Identity.email?(), do: "ada@example.org", else: "ada"
    account = Repo.insert!(User.changeset(%User{}, %{username: inviter}))
    conn = build_conn() |> Plug.Test.init_test_session(%{}) |> Gate.log_in(account)

    {:ok, view, _html} = live(conn, ~p"/invitations")

    view |> form("#invitation-form", %{"username" => value}) |> render_submit()
  end

  # The codes are the library's and say `username` whatever the mode is. The sentence this
  # application answers with is the part that has to know.
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

    addressing()

    assert CeremonyMessages.message("username_required", nil) =~ "address"
  end
end
