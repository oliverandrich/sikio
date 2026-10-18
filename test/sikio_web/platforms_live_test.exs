# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlatformsLiveTest do
  @moduledoc """
  The platforms page lets an administrator switch each platform on or off. A change saves at once.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Platforms
  alias Sikio.Repo

  defp account(attrs \\ %{}),
    do: Repo.insert!(struct(%User{username: unique_username()}, attrs))

  defp signed_in(conn, account), do: conn |> init_test_session(%{}) |> Gate.log_in(account)

  test "an administrator switches a platform off, and it saves at once", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, account(%{admin: true})), ~p"/platforms")

    for kind <- ~w(podcast youtube peertube mediathek),
        do: assert(has_element?(view, ~s|#platform-#{kind}[role="switch"][checked]|))

    view
    |> form("#platforms-form", %{"platforms" => %{"youtube" => "false"}})
    |> render_change()

    refute Platforms.enabled?(:youtube)
    assert Platforms.enabled?(:podcast)
    assert has_element?(view, "#platforms-saved", "Saved.")
    refute has_element?(view, "#platform-youtube[checked]")
    assert has_element?(view, ~s|#breadcrumb a[href="/account/settings"]|)
  end

  test "a member is sent to the settings", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/account/settings"}}} =
             live(signed_in(conn, account()), ~p"/platforms")
  end

  test "the settings link the platforms page for administrators", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, account(%{admin: true})), ~p"/account/settings")
    assert has_element?(view, ~s|#settings-admin a[href="/platforms"]|)
  end
end
