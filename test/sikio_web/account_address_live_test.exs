# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AccountAddressLiveTest do
  @moduledoc """
  Changing the address an account is identified by, from the settings to the confirmation.

  Asking needs a passkey confirmation from the last five minutes. The link goes to the new
  address and confirms only for the account that asked. The old address hears of the change.
  """
  # Not async: these tests set the identifier mode and the mail recipient in application env.
  use SikioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Ithibati.Web.Gate
  alias Sikio.AccountAddress
  alias Sikio.Accounts.User
  alias Sikio.Repo
  alias Sikio.TestConfig

  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    TestConfig.put_env(:sikio, :account_identity, :email)
    TestConfig.put_env(:sikio, :mail_from, {"Sikio", "sikio@example.org"})

    ada = Repo.insert!(User.changeset(%User{}, %{username: "ada@example.org"}))
    %{ada: ada, conn: signed_in(ada)}
  end

  defp signed_in(account, confirmed? \\ true) do
    conn = build_conn() |> init_test_session(%{}) |> Gate.log_in(account)
    if confirmed?, do: confirmed(conn, account), else: conn
  end

  defp failing_mailer,
    do:
      TestConfig.put_env(:sikio, Sikio.Mailer,
        adapter: SikioWeb.InvitationDeliveryTest.FailingAdapter
      )

  test "the settings lead to the address in email mode only", c do
    {:ok, view, _} = live(c.conn, ~p"/account/settings")
    assert has_element?(view, ~s|a[href="/account/address"]|, "ada@example.org")

    TestConfig.put_env(:sikio, :account_identity, :username)
    {:ok, view, _} = live(c.conn, ~p"/account/settings")
    refute has_element?(view, ~s|a[href="/account/address"]|)

    assert {:error, {:live_redirect, %{to: "/account/settings"}}} =
             live(c.conn, ~p"/account/address")
  end

  test "asking needs a passkey confirmation from the last five minutes", c do
    assert {:error, {:redirect, %{to: "/account/confirm/address"}}} =
             live(signed_in(c.ada, false), ~p"/account/address")
  end

  test "asking mails a link to the new address and keeps the old one", c do
    {:ok, view, _} = live(c.conn, ~p"/account/address")

    view |> form("#address-form", %{"address" => "ada@new.example"}) |> render_submit()

    assert_email_sent(fn email ->
      assert {_name, "ada@new.example"} = hd(email.to)
      # The token follows `#`, which no request sends and no access log records.
      assert email.text_body =~ ~r|/account/address/confirm#[\w-]{20,}|
    end)

    assert has_element?(view, "#address-pending", "ada@new.example")
    assert Repo.reload!(c.ada).username == "ada@example.org"
  end

  test "an address that names another account is refused", c do
    Repo.insert!(User.changeset(%User{}, %{username: "grace@example.org"}))
    {:ok, view, _} = live(c.conn, ~p"/account/address")

    html = view |> form("#address-form", %{"address" => "grace@example.org"}) |> render_submit()

    assert html =~ "already names another account"
    refute_email_sent()
  end

  test "the link confirms the new address and tells the old one", c do
    {:ok, _request, token} = AccountAddress.request(c.ada, "ada@new.example")
    {:ok, view, _} = live(c.conn, ~p"/account/address/confirm")
    render_hook(view, "address-token", %{"token" => token})
    assert has_element?(view, "#address-confirm", "ada@new.example")

    view |> element("#address-confirm button") |> render_click()

    assert_redirect(view, "/account/settings")
    assert Repo.reload!(c.ada).username == "ada@new.example"

    assert_email_sent(fn email ->
      assert {_name, "ada@example.org"} = hd(email.to)
      assert email.text_body =~ "ada@new.example"
    end)
  end

  # Each request mails a stranger's address, so an account has a daily budget, like invitations.
  test "requests beyond the daily budget are refused", c do
    TestConfig.put_budget(:address, {1, 86_400})
    {:ok, view, _} = live(c.conn, ~p"/account/address")

    view |> form("#address-form", %{"address" => "one@example.org"}) |> render_submit()
    assert_email_sent()

    html = view |> form("#address-form", %{"address" => "two@example.org"}) |> render_submit()
    assert html =~ "Too many requests"
    refute_email_sent()
  end

  # The notice is the old address's only warning, so a failed one is said.
  test "a notice that cannot be sent is said", c do
    {:ok, _request, token} = AccountAddress.request(c.ada, "ada@new.example")

    failing_mailer()

    {:ok, view, _} = live(c.conn, ~p"/account/address/confirm")
    render_hook(view, "address-token", %{"token" => token})

    view |> element("#address-confirm button") |> render_click()

    flash = assert_redirect(view, "/account/settings")
    assert flash["error"] =~ "could not be told"
    assert Repo.reload!(c.ada).username == "ada@new.example"
  end

  # Signed out, the page keeps the token in the tab and asks for a sign-in. Gate's redirect
  # would carry the fragment to the sign-in page.
  test "the link asks a signed-out visitor to sign in first", c do
    {:ok, _request, token} = AccountAddress.request(c.ada, "ada@new.example")
    {:ok, view, _} = live(build_conn(), ~p"/account/address/confirm")

    html = render_hook(view, "address-token", %{"token" => token})
    assert html =~ "Sign in"
    refute has_element?(view, "#address-confirm button")
    assert Repo.reload!(c.ada).username == "ada@example.org"
  end

  # A request whose link could not be mailed would wait for nothing, so it is withdrawn.
  test "a link that cannot be mailed leaves no request", c do
    failing_mailer()

    {:ok, view, _} = live(c.conn, ~p"/account/address")
    html = view |> form("#address-form", %{"address" => "ada@new.example"}) |> render_submit()

    assert html =~ "could not be sent"
    refute has_element?(view, "#address-pending")
    assert AccountAddress.pending(c.ada) == nil
  end

  # A link that cannot be mailed replaces nothing; the earlier link keeps working.
  test "a failed mail keeps the earlier request", c do
    {:ok, _request, _token} = AccountAddress.request(c.ada, "first@example.org")

    failing_mailer()

    {:ok, view, _} = live(c.conn, ~p"/account/address")
    view |> form("#address-form", %{"address" => "second@example.org"}) |> render_submit()

    assert %{address: "first@example.org"} = AccountAddress.pending(c.ada)
    assert has_element?(view, "#address-pending", "first@example.org")
  end

  # Another account, signed in with the link, changes nothing.
  test "the link confirms nothing for another account", c do
    {:ok, _request, token} = AccountAddress.request(c.ada, "ada@new.example")
    grace = Repo.insert!(User.changeset(%User{}, %{username: "grace@example.org"}))

    {:ok, view, _} = live(signed_in(grace), ~p"/account/address/confirm")

    assert render_hook(view, "address-token", %{"token" => token}) =~
             "This link is no longer valid"

    refute has_element?(view, "#address-confirm button")
    assert Repo.reload!(c.ada).username == "ada@example.org"
  end
end
