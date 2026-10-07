# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationDeliveryTest do
  @moduledoc """
  Invitation delivery in username mode and email mode.

  In username mode the inviter gets a link to pass on, and no mail is sent.
  In email mode the link is mailed to the invitee's address.
  The link is still shown, so a failed delivery does not lose the invitation.
  """
  # async: false, because these tests change the identity mode and mail configuration.
  use SikioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Repo
  alias Sikio.TestConfig

  defmodule FailingAdapter do
    @moduledoc false
    use Swoosh.Adapter, required_config: []

    def deliver(_email, _config), do: {:error, :smtp_unavailable}
  end

  defmodule RaisingAdapter do
    @moduledoc false
    use Swoosh.Adapter, required_config: []

    def deliver(_email, _config), do: raise("the submission server said something unreadable")
  end

  setup %{conn: conn} do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)

    account = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))

    %{conn: conn |> init_test_session(%{}) |> Gate.log_in(account)}
  end

  defp addressing do
    TestConfig.put_env(:sikio, :account_identity, :email)
    TestConfig.put_env(:sikio, :mail_from, {"Sikio", "sikio@example.org"})
  end

  defp invite(conn, identifier) do
    {:ok, view, _html} = live(conn, ~p"/invitations")

    view |> form("#invitation-form", %{"username" => identifier}) |> render_submit()

    view
  end

  test "a named guest is given a link and nothing is sent", %{conn: conn} do
    view = invite(conn, "grace_hopper")

    assert render(view) =~ "/invite/"
    refute_email_sent()
  end

  test "an addressed guest is sent the link, and still shown it", %{conn: conn} do
    addressing()

    view = invite(conn, "grace@example.org")
    html = render(view)

    assert html =~ "/invite/"

    assert_email_sent(fn email ->
      assert {_name, "grace@example.org"} = hd(email.to)
      assert email.text_body =~ "/invite/"
    end)
  end

  # A mail server outage must not lose a stored invitation.
  # The page reports the failure and still shows the link.
  test "a delivery that fails says so and leaves the link standing", %{conn: conn} do
    addressing()
    TestConfig.put_env(:sikio, Sikio.Mailer, adapter: FailingAdapter)

    view = invite(conn, "grace@example.org")
    html = render(view)

    assert html =~ "/invite/"
    assert html =~ "could not be sent"
  end

  # Swoosh raises when its adapter rejects the configuration, and gen_smtp raises on unusable
  # values. The invitation is stored by then, and its token exists only in the LiveView process.
  # A raise would lose the only copy of the link.
  test "a delivery that raises loses neither the invitation nor the link", %{conn: conn} do
    addressing()
    TestConfig.put_env(:sikio, Sikio.Mailer, adapter: RaisingAdapter)

    view = invite(conn, "grace@example.org")
    html = render(view)

    assert html =~ "/invite/"
    assert html =~ "could not be sent"
  end

  # In email mode the form asks for an address, so nobody enters a username the server rejects.
  test "the form asks for an address when that is what an account is", %{conn: conn} do
    addressing()

    {:ok, _view, html} = live(conn, ~p"/invitations")

    assert html =~ ~s(type="email")
    refute html =~ "Their username"
  end
end
