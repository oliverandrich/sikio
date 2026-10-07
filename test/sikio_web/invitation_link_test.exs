# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationLinkTest do
  @moduledoc """
  Responses to invitation links that can no longer be accepted.
  """
  use SikioWeb.ConnCase, async: true

  alias Sikio.Accounts.User
  alias Sikio.Invitations
  alias Sikio.Repo

  # A used token and an unknown token get the same page.
  # Distinct pages would reveal which guessed tokens once existed.
  test "a spent link and an invented one are answered exactly alike", %{conn: conn} do
    member = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, invitation} = Invitations.open(member, %{"username" => unique_username()})
    invitation |> Ecto.Changeset.change(accepted_at: DateTime.utc_now()) |> Repo.update!()

    spent = main_text(conn, "/invite/#{invitation.token}")
    invented = main_text(conn, "/invite/a-token-nobody-ever-held")

    # Compares the full text, because any difference reveals the token's state.
    assert spent == invented
    assert spent =~ "has been used already, or it has expired"
  end

  defp main_text(conn, path) do
    conn
    |> get(path)
    |> html_response(200)
    |> LazyHTML.from_document()
    |> LazyHTML.query("main")
    |> LazyHTML.text()
  end
end
