# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AccountsLiveTest do
  @moduledoc """
  The accounts page lists every account for administrators. Members never reach it.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

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
end
