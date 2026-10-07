# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SetupCodeTest do
  @moduledoc """
  Setup code protection of the first account. Every instance requires it.

  async: false, because two tests set the rate-limit budget in shared application configuration.
  Synchronous tests run after all async tests, so no other test reads it meanwhile.
  """
  use SikioWeb.ConnCase, async: false

  alias Ithibati.Identity.Instance
  alias Sikio.Accounts.User
  alias Sikio.Repo
  alias Sikio.TestConfig
  alias SikioWeb.Auth

  import Phoenix.LiveViewTest

  setup do
    {:ok, code} = Instance.issue_code()
    %{code: code, conn: Plug.Test.init_test_session(build_conn(), %{})}
  end

  defp key_attrs,
    do: %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)}

  # A unique private address per test, which `SikioWeb.ClientIp` leaves unchanged.
  # The attempt counter is global and persists across files. The browser suite spends the
  # default budget from loopback, so a shared address could be refused for other files' attempts.
  defp own_peer do
    n = System.unique_integer([:positive])
    {10, n |> div(65_536) |> rem(256), n |> div(256) |> rem(256), rem(n, 256)}
  end

  defp exchange(conn, code, peer \\ nil) do
    conn
    |> Map.put(:remote_ip, peer || own_peer())
    |> post(~p"/setup/code", %{"setup_code" => code})
  end

  # The form alone is no protection. A direct ceremony request without a proof must be refused.
  test "a first-account challenge without a proof is refused", %{conn: conn} do
    assert {:error, _reason} =
             Auth.registration_subject(conn, %{"username" => unique_username()})
  end

  test "a first-account registration without a proof creates nobody", %{conn: conn} do
    assert {:error, _reason} = Auth.register(conn, key_attrs(), unique_username(), %{})
    assert Repo.aggregate(User, :count) == 0
    assert Instance.needs_setup?()
  end

  test "a code exchanged for a proof opens the claim", %{conn: conn, code: code} do
    {:ok, proof} = Instance.authorize_code(code)
    conn = Plug.Conn.put_session(conn, :setup_authorization, proof)

    assert {:ok, username} = Auth.registration_subject(conn, %{"username" => "ada"})
    assert username == "ada"

    assert {:ok, _conn} = Auth.register(conn, key_attrs(), unique_username(), %{})
    refute Instance.needs_setup?()
  end

  # One code creates one account.
  test "a proof is spent by the account it made", %{conn: conn, code: code} do
    {:ok, proof} = Instance.authorize_code(code)
    conn = Plug.Conn.put_session(conn, :setup_authorization, proof)

    assert {:ok, _conn} = Auth.register(conn, key_attrs(), unique_username(), %{})
    assert Repo.aggregate(User, :count) == 1
  end

  # Issuing a new code revokes the old one. A proof obtained with the old code must stop
  # working too. Otherwise rotation only affects future exchanges.
  test "a proof stops standing when the operator issues another code", %{conn: conn, code: code} do
    {:ok, proof} = Instance.authorize_code(code)
    conn = Plug.Conn.put_session(conn, :setup_authorization, proof)

    assert {:ok, _} = Auth.registration_subject(conn, %{"username" => "ada"})

    {:ok, _newer} = Instance.issue_code()

    assert {:error, :setup_authorization_required} =
             Auth.registration_subject(conn, %{"username" => "ada"})

    assert {:error, _reason} = Auth.register(conn, key_attrs(), unique_username(), %{})
    assert Instance.needs_setup?()
  end

  describe "the page a visitor meets" do
    test "asks for the code before it asks for a name", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/setup")

      assert html =~ "setup-code-form"
      refute html =~ "claim-form"
      refute html =~ "Choose your username", "the page says what it is actually asking for"
    end

    test "asks for a name once the code has been spent", %{conn: conn, code: code} do
      conn = exchange(conn, code)
      assert redirected_to(conn) == ~p"/setup"

      {:ok, _view, html} = live(conn, ~p"/setup")

      assert html =~ "claim-form"
      refute html =~ "setup-code-form"
    end

    # An unknown code stores no proof, and the response does not say why it failed.
    test "a code it does not know changes nothing", %{conn: conn} do
      conn = exchange(conn, "not-the-code")

      assert redirected_to(conn) == ~p"/setup"
      assert get_session(conn, :setup_authorization) == nil

      {:ok, _view, html} = live(build_conn() |> Plug.Test.init_test_session(%{}), ~p"/setup")
      assert html =~ "setup-code-form"
    end

    # Codes invite guessing, so every attempt spends the budget, not only wrong ones.
    # The refusal carries `Retry-After` and no proof, even for the correct code.
    test "too many attempts are refused with a wait, whatever the codes were", %{code: code} do
      TestConfig.put_budget(:setup, {2, 60})

      # All three attempts use one address, so they share one budget.
      peer = own_peer()

      guessing = fn body ->
        build_conn() |> Plug.Test.init_test_session(%{}) |> exchange(body, peer)
      end

      guessing.("wrong-one")
      guessing.("wrong-two")
      refused = guessing.(code)

      assert [wait] = get_resp_header(refused, "retry-after")
      assert String.to_integer(wait) > 0
      assert get_session(refused, :setup_authorization) == nil
      assert Instance.needs_setup?()
    end

    # `build_conn/0` skips CSRF protection, so the other tests bypass a check the router enforces.
    # On a protected instance this form is the only entry, so its rendered token must pass.
    test "the token the form renders is accepted by forgery protection", %{code: code} do
      rendered = get(build_conn(), ~p"/setup")
      html = html_response(rendered, 200)

      assert [_, token] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]*)"/, html)

      posted =
        rendered
        |> recycle()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> Map.put(:remote_ip, own_peer())
        |> post(~p"/setup/code", %{"setup_code" => code, "_csrf_token" => token})

      assert redirected_to(posted) == ~p"/setup"
      assert get_session(posted, :setup_authorization)
    end

    # Behind a reverse proxy every request has the same socket address. Counting it would give
    # everyone one budget, so a stranger could lock the operator out.
    # The forwarded address is counted instead.
    test "two visitors behind one proxy do not spend each other's budget", %{code: code} do
      TestConfig.put_budget(:setup, {1, 60})

      guessing = fn address, body ->
        build_conn()
        |> Plug.Conn.put_req_header("x-forwarded-for", address)
        |> Plug.Test.init_test_session(%{})
        |> post(~p"/setup/code", %{"setup_code" => body})
      end

      guessing.("203.0.113.7", "wrong-one")

      assert [_wait] = guessing.("203.0.113.7", code) |> get_resp_header("retry-after")

      # The second address has spent no attempts.
      spent = guessing.("198.51.100.4", code)

      assert get_resp_header(spent, "retry-after") == []
      assert get_session(spent, :setup_authorization)
    end

    test "the exchange is never cached", %{conn: conn, code: code} do
      conn = exchange(conn, code)

      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    # The proof lasts ten minutes. An expired proof shows the code form again,
    # instead of a refusal after the passkey prompt.
    test "an expired proof sends the visitor back to the code", %{conn: conn} do
      conn =
        Plug.Conn.put_session(conn, :setup_authorization, %{
          digest: :crypto.strong_rand_bytes(32),
          expires_at: 0
        })

      {:ok, _view, html} = live(conn, ~p"/setup")

      assert html =~ "setup-code-form"
    end
  end
end
