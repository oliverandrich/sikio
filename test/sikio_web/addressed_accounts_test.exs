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
