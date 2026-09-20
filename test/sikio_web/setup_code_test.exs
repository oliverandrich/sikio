# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SetupCodeTest do
  @moduledoc """
  The gate in front of the first account, on an instance that protects its claim.

  Not `async: true`: the claim mode is application configuration and these set it. Synchronous
  tests run after every concurrent one, so nothing else reads it while they do.
  """
  use SikioWeb.ConnCase, async: false

  alias Ithibati.Identity.Instance
  alias Sikio.Accounts.User
  alias Sikio.Repo
  alias Sikio.TestConfig
  alias SikioWeb.Auth

  import Phoenix.LiveViewTest

  setup do
    TestConfig.put_env(:ithibati, :initial_claim, :operator_code)

    {:ok, code} = Instance.issue_code()
    %{code: code, conn: Plug.Test.init_test_session(build_conn(), %{})}
  end

  defp key_attrs,
    do: %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)}

  # The form is not the gate. Somebody who never loads it and posts straight at the ceremony has
  # to meet the same refusal, or the protection is decoration.
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

  # One code, one account. A proof that was already spent must not make a second.
  test "a proof is spent by the account it made", %{conn: conn, code: code} do
    {:ok, proof} = Instance.authorize_code(code)
    conn = Plug.Conn.put_session(conn, :setup_authorization, proof)

    assert {:ok, _conn} = Auth.register(conn, key_attrs(), unique_username(), %{})
    assert Repo.aggregate(User, :count) == 1
  end

  # An operator who issues a second code has decided the first should not work, and somebody may
  # be holding a proof bought with it. Rotation has to reach that proof, or the decision is only
  # about who gets in next rather than who gets in.
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
      conn = post(conn, ~p"/setup/code", %{"setup_code" => code})
      assert redirected_to(conn) == ~p"/setup"

      {:ok, _view, html} = live(conn, ~p"/setup")

      assert html =~ "claim-form"
      refute html =~ "setup-code-form"
    end

    # A wrong code and an invented one answer alike, and neither says which it was.
    test "a code it does not know changes nothing", %{conn: conn} do
      conn = post(conn, ~p"/setup/code", %{"setup_code" => "not-the-code"})

      assert redirected_to(conn) == ~p"/setup"
      assert get_session(conn, :setup_authorization) == nil

      {:ok, _view, html} = live(build_conn() |> Plug.Test.init_test_session(%{}), ~p"/setup")
      assert html =~ "setup-code-form"
    end

    # Guessing is what a code invites, so the budget is spent by attempts rather than by wrong
    # ones. The wait is told; nothing about the code is.
    test "too many attempts are refused with a wait, whatever the codes were", %{code: code} do
      TestConfig.put_env(:sikio, :auth_rate_limits, setup: {2, 60})

      # Its own address, because the counter is global and every other test shares the default.
      guessing = fn body ->
        build_conn()
        |> Map.put(:remote_ip, {198, 51, 100, 7})
        |> Plug.Test.init_test_session(%{})
        |> post(~p"/setup/code", %{"setup_code" => body})
      end

      guessing.("wrong-one")
      guessing.("wrong-two")
      refused = guessing.(code)

      assert [wait] = get_resp_header(refused, "retry-after")
      assert String.to_integer(wait) > 0
      assert get_session(refused, :setup_authorization) == nil
      assert Instance.needs_setup?()
    end

    # `build_conn/0` waives forgery protection, so every other test here posts through a door the
    # router does not actually leave open. On a protected instance this form is the only way in,
    # which makes the token it renders part of the gate rather than decoration.
    test "the token the form renders is accepted by forgery protection", %{code: code} do
      rendered = get(build_conn(), ~p"/setup")
      html = html_response(rendered, 200)

      assert [_, token] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]*)"/, html)

      posted =
        rendered
        |> recycle()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/setup/code", %{"setup_code" => code, "_csrf_token" => token})

      assert redirected_to(posted) == ~p"/setup"
      assert get_session(posted, :setup_authorization)
    end

    # The route is registered whatever the instance decided, so an instance that never asks for a
    # code still answers this address. A stranger posting at it must be turned away rather than
    # shown a crash, which is what the library raises when no code was ever meant to exist.
    test "an instance that leaves its claim open refuses the exchange", %{conn: conn, code: code} do
      Application.put_env(:ithibati, :initial_claim, :open)

      conn = post(conn, ~p"/setup/code", %{"setup_code" => code})

      assert redirected_to(conn) == ~p"/setup"
      assert get_session(conn, :setup_authorization) == nil
    end

    test "the exchange is never cached", %{conn: conn, code: code} do
      conn = post(conn, ~p"/setup/code", %{"setup_code" => code})

      assert get_resp_header(conn, "cache-control") == ["no-store"]
    end

    # The proof lasts ten minutes. Somebody slower than that meets the code field again rather
    # than a refusal after the passkey dialogue.
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
