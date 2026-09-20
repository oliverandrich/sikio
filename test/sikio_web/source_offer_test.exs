# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SourceOfferTest do
  @moduledoc """
  What the licence obliges the running application to say.

  Section 13 of the AGPL is the reason this licence exists: whoever runs Sikio for other people
  has to offer those people its source. A link is that offer, so it is pinned here rather than
  trusted to survive the next change to a layout.
  """
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Repo

  @configured Application.compile_env(:sikio, :source_url)

  test "a signed-in reader is offered the source", %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: "listener"}))
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ @configured
  end

  # Somebody who has not signed in is still interacting with the application over a network, and
  # on a fresh instance the first thing they meet is the setup page.
  test "so is a visitor who has not signed in", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/setup")

    assert html =~ @configured
  end

  # A marker in a template is a comment the compiler removes, but the newline after it is not
  # a comment. Every answer would then begin with whitespace before the doctype, which browsers
  # forgive and tools that read the first characters do not.
  test "the document still begins with its doctype", %{conn: conn} do
    body = conn |> get(~p"/setup") |> response(200)

    assert String.starts_with?(body, "<!DOCTYPE html>")
  end
end
