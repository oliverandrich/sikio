# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AccountsLiveTest do
  @moduledoc """
  The accounts page lists every account for administrators. Members never reach it.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ithibati.Identity.Sessions
  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Repo

  defp account(attrs \\ %{}),
    do: Repo.insert!(struct(%User{username: unique_username(), name: nil}, attrs))

  defp signed_in(conn, account), do: conn |> init_test_session(%{}) |> Gate.log_in(account)

  test "an administrator sees every account with its role", %{conn: conn} do
    admin = account(%{admin: true})
    member = account()

    {:ok, view, _} = live(signed_in(conn, admin), ~p"/accounts")

    assert has_element?(view, "#account-#{admin.id}", admin.username)
    assert has_element?(view, "#account-#{admin.id}", "Administrator")
    assert has_element?(view, "#account-#{member.id}", member.username)
    assert has_element?(view, "#account-#{member.id}", "Member")
    assert has_element?(view, ~s|#nav-back[href="/account/settings"]|)
    assert has_element?(view, ~s|#breadcrumb a[href="/account/settings"]|)
    assert has_element?(view, ~s|#breadcrumb [aria-current="page"]|, "Accounts")
  end

  test "a member is sent to the settings", %{conn: conn} do
    member = account()

    assert {:error, {:redirect, %{to: "/account/settings", flash: flash}}} =
             live(signed_in(conn, member), ~p"/accounts")

    assert flash["error"] =~ "administrators"
  end

  # A full page load would remount the player in the root layout and stop playback.
  test "the settings reach the accounts page by live navigation", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, account(%{admin: true})), ~p"/account/settings")

    assert has_element?(view, ~s|#settings-admin a[href="/accounts"]|)
    # A different live_session would answer with a full redirect instead.
    assert {:ok, accounts, _html} = live_redirect(view, to: ~p"/accounts")
    assert has_element?(accounts, "#accounts")
  end

  test "the settings link the accounts page for administrators only", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, account(%{admin: true})), ~p"/account/settings")
    assert has_element?(view, ~s|#settings-admin a[href="/accounts"]|)

    {:ok, view, _} = live(signed_in(conn, account()), ~p"/account/settings")
    refute has_element?(view, "#settings-admin")
  end

  test "an administrator grants and revokes the role on a row", %{conn: conn} do
    admin = account(%{admin: true})
    member = account()
    {:ok, view, _} = live(conn |> signed_in(admin) |> confirmed(admin), ~p"/accounts")

    view |> element(~s|#account-#{member.id} [data-action="grant"]|) |> render_click()
    assert has_element?(view, "#account-#{member.id}", "Administrator")

    view |> element(~s|#account-#{member.id} [data-action="revoke"]|) |> render_click()
    assert has_element?(view, "#account-#{member.id}", "Member")
    refute Repo.reload!(member).admin
  end

  # A new administrator could remove any account, so granting the role asks for the passkey too.
  test "granting without a recent confirmation asks for it first", %{conn: conn} do
    admin = account(%{admin: true})
    member = account()
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/accounts")

    assert {:error, {:redirect, %{to: "/account/confirm/accounts"}}} =
             view |> element(~s|#account-#{member.id} [data-action="grant"]|) |> render_click()

    refute Repo.reload!(member).admin
  end

  test "the own row offers no actions, and a forged event removes nothing", %{conn: conn} do
    admin = account(%{admin: true})
    {:ok, view, _} = live(conn |> signed_in(admin) |> confirmed(admin), ~p"/accounts")

    refute has_element?(view, "#account-#{admin.id} [data-action]")
    render_click(view, "remove", %{"id" => to_string(admin.id)})
    refute has_element?(view, "#remove-confirm")
  end

  # Removing an account cannot be undone, so it asks for the passkey first, as the account's
  # security settings do.
  test "removing without a recent confirmation asks for it first", %{conn: conn} do
    admin = account(%{admin: true})
    member = account()
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/accounts")

    assert {:error, {:redirect, %{to: "/account/confirm/accounts"}}} =
             view |> element(~s|#account-#{member.id} [data-action="remove"]|) |> render_click()

    assert Repo.get(User, member.id)

    conn = get(signed_in(conn, admin), ~p"/account/confirm/accounts")
    assert redirected_to(conn) == "/account/verify"
    assert get_session(conn, :reauth_target) == "/accounts"
    assert {:ok, _verify, _html} = live(conn, ~p"/account/verify")
  end

  test "a confirmed administrator removes an account and its open pages", %{conn: conn} do
    admin = account(%{admin: true})
    member = account()
    token = Sessions.generate_session_token(member)
    SikioWeb.Endpoint.subscribe(Gate.live_socket_id(token))
    {:ok, view, _} = live(conn |> signed_in(admin) |> confirmed(admin), ~p"/accounts")

    view |> element(~s|#account-#{member.id} [data-action="remove"]|) |> render_click()
    assert has_element?(view, "#remove-confirm", member.username)

    view |> element("#confirm-remove") |> render_click()
    refute has_element?(view, "#account-#{member.id}")
    assert render(view) =~ "Removed #{member.username}."
    refute Repo.get(User, member.id)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
  end

  test "cancelling the dialog removes nothing", %{conn: conn} do
    admin = account(%{admin: true})
    member = account()
    {:ok, view, _} = live(conn |> signed_in(admin) |> confirmed(admin), ~p"/accounts")

    view |> element(~s|#account-#{member.id} [data-action="remove"]|) |> render_click()
    view |> element("#cancel-remove") |> render_click()
    refute has_element?(view, "#remove-confirm")
    assert Repo.get(User, member.id)
  end
end
