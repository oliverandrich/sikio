# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationLinkTest do
  @moduledoc """
  What a link answers once it can no longer be accepted.
  """
  use SikioWeb.ConnCase, async: true

  alias Sikio.Accounts.User
  alias Sikio.Invitations
  alias Sikio.Repo

  # A used link, an expired one and one nobody ever held are one answer on purpose: anything else
  # tells a guesser which of their guesses was once real.
  test "a spent link and an invented one are answered exactly alike", %{conn: conn} do
    member = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, invitation} = Invitations.open(member, %{"username" => unique_username()})
    invitation |> Ecto.Changeset.change(accepted_at: DateTime.utc_now()) |> Repo.update!()

    spent = main_text(conn, "/invite/#{invitation.token}")
    invented = main_text(conn, "/invite/a-token-nobody-ever-held")

    # Word for word, because anything else is a signal.
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
