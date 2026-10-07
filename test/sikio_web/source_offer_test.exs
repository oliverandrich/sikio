# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SourceOfferTest do
  @moduledoc """
  The source code offer required by the licence.

  AGPL section 13 requires whoever runs Sikio for others to offer them its source.
  A link is that offer. These tests keep it present across layout changes.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Repo

  @configured Application.compile_env(:sikio, :source_url)

  test "a signed-in reader is offered the source", %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ @configured
  end

  # Member pages have no footer. The sidebar colophon links the source on desktop.
  # The about overview, opened from the account menu, links it on every page.
  test "a signed-in reader finds it in the overview about Sikio", %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)

    {:ok, view, html} = live(conn, ~p"/")

    assert has_element?(view, "#user-menu #show-about")
    assert has_element?(view, ~s|#colophon a[href="#{@configured}"]|)
    assert has_element?(view, "#colophon", "AGPL-3.0")
    assert has_element?(view, ~s|#about a[href="#{@configured}"]|)
    refute html =~ "<footer"
  end

  # The source is external, so the link opens in a new tab like other external links.
  test "the offer opens in a tab of its own", %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             ~s|#colophon a[href="#{@configured}"][target="_blank"][rel="noopener noreferrer"]|
           )
  end

  # Anonymous visitors also use the application over a network.
  # On a fresh instance the setup page is the first page they see.
  test "so is a visitor who has not signed in", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup")

    assert html =~ @configured
  end

  # The compiler removes a template comment but keeps the newline after it.
  # The response would then start with whitespace before the doctype.
  # Browsers accept that; tools that check the first bytes do not.
  test "the document still begins with its doctype", %{conn: conn} do
    body = conn |> get(~p"/setup") |> response(200)

    assert String.starts_with?(body, "<!DOCTYPE html>")
  end
end
