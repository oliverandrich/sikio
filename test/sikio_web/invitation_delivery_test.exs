# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationDeliveryTest do
  @moduledoc """
  What happens to an invitation once it exists, in each of the two modes.

  An instance names its accounts or addresses them. Named, an invitation is a link its sender
  passes on however they like, and nothing is sent. Addressed, the invitee's identifier *is* an
  address, so the link goes to it — and the link is still shown, because a delivery that failed
  must not take the invitation with it.
  """
  # async: false — the mode and the mail configuration are application configuration.
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

  # A mail server that is down is not a reason to lose an invitation that already exists. The
  # sender is told, and the link they can pass on by hand is right there.
  test "a delivery that fails says so and leaves the link standing", %{conn: conn} do
    addressing()
    TestConfig.put_env(:sikio, Sikio.Mailer, adapter: FailingAdapter)

    view = invite(conn, "grace@example.org")
    html = render(view)

    assert html =~ "/invite/"
    assert html =~ "could not be sent"
  end

  # Swoosh raises rather than answers for a configuration its adapter refuses, and gen_smtp does
  # the same for a value it cannot use. The invitation is written by then and its token lives in
  # this process alone, so a raise would take the only copy of the link with it.
  test "a delivery that raises loses neither the invitation nor the link", %{conn: conn} do
    addressing()
    TestConfig.put_env(:sikio, Sikio.Mailer, adapter: RaisingAdapter)

    view = invite(conn, "grace@example.org")
    html = render(view)

    assert html =~ "/invite/"
    assert html =~ "could not be sent"
  end

  # The form asks for what the mode can actually use, so nobody types a name into an instance
  # that will refuse it after the fact.
  test "the form asks for an address when that is what an account is", %{conn: conn} do
    addressing()

    {:ok, _view, html} = live(conn, ~p"/invitations")

    assert html =~ ~s(type="email")
    refute html =~ "Their username"
  end
end
