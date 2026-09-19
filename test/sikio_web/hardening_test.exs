defmodule SikioWeb.HardeningTest do
  use SikioWeb.ConnCase

  alias Ithibati.Identity.RecoveryCodes
  alias Ithibati.Identity.Sessions
  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Repo
  alias SikioWeb.Auth

  defp signed do
    {:ok, conn} =
      Auth.register(
        init_test_session(build_conn(), %{}),
        %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)},
        "ada",
        %{}
      )

    {init_test_session(build_conn(), get_session(conn)), Repo.get_by!(User, username: "ada")}
  end

  test "health is public, minimal and does not set a session", %{conn: conn} do
    conn = get(conn, "/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
    refute Map.has_key?(conn.resp_cookies, "_starter_auth_key")
  end

  test "sensitive changes require a fresh confirmation" do
    {conn, account} = signed()
    conn = assign(conn, :current_account, account)

    assert {:error, :reauthentication_required} =
             Auth.registration_subject(conn, %{"intent" => "add_passkey"})

    assert conn |> post("/account/recovery-codes", %{"confirm" => "true"}) |> redirected_to() ==
             "/account/confirm/recovery-codes"
  end

  test "confirmation is bound to the current account and expires" do
    {conn, account} = signed()
    conn = conn |> get("/account/confirm/passkeys") |> recycle() |> get("/account/verify")
    assert html_response(conn, 200) =~ "Confirm your identity"

    conn =
      build_conn() |> init_test_session(get_session(conn)) |> assign(:current_account, account)

    other = Repo.insert!(User.changeset(%User{}, %{username: "grace"}))
    assert {:error, :account_mismatch} = Auth.authenticate(conn, other)
    assert {:ok, confirmed} = Auth.authenticate(conn, account)
    assert json_response(confirmed, 200)["redirect"] == "/account/passkeys"
    assert {:ok, ^account} = Auth.registration_subject(confirmed, %{"intent" => "add_passkey"})

    expired =
      build_conn()
      |> init_test_session(get_session(confirmed))
      |> assign(:current_account, account)
      |> put_session(:confirmed_at, System.system_time(:second) - 301)

    assert {:error, :reauthentication_required} =
             Auth.registration_subject(expired, %{"intent" => "add_passkey"})
  end

  test "recovery confirms the same account and preserves a last-code replacement batch" do
    {conn, account} = signed()
    conn = get(conn, "/account/confirm/passkeys")

    conn =
      build_conn() |> init_test_session(get_session(conn)) |> assign(:current_account, account)

    fresh = RecoveryCodes.regenerate(account)
    assert {:ok, confirmed} = Auth.recovered(conn, account, fresh)
    assert json_response(confirmed, 200)["redirect"] == "/recovery-codes"
    assert get_session(confirmed, :recovery_codes) == fresh
    assert get_session(confirmed, :confirmed_at)
  end

  test "recovery attempts are limited by remote IP, with Retry-After" do
    ip = {192, 0, 2, 123}

    for _ <- 1..10 do
      conn = %{build_conn() | remote_ip: ip} |> post("/auth/recovery", %{"code" => "invalid"})
      refute conn.status == 429
    end

    blocked = %{build_conn() | remote_ip: ip} |> post("/auth/recovery", %{"code" => "invalid"})
    assert json_response(blocked, 429)["error"] == "rate_limited"
    assert [seconds] = get_resp_header(blocked, "retry-after")
    assert String.to_integer(seconds) > 0
  end

  test "signing out everywhere revokes this session and another device" do
    {conn, account} = signed()
    token = get_session(conn, Gate.session_key())
    other = Sessions.generate_session_token(account)
    result = delete(conn, "/account/sessions")
    assert redirected_to(result) == "/login"
    refute Sessions.get_user_by_session_token(token)
    refute Sessions.get_user_by_session_token(other)
    refute get_session(result, Gate.session_key())
  end

  test "an expired session with a pending confirmation can sign in normally" do
    {conn, account} = signed()
    conn = get(conn, "/account/confirm/passkeys")
    conn = build_conn() |> init_test_session(get_session(conn)) |> assign(:current_account, nil)
    assert {:ok, result} = Auth.authenticate(conn, account)
    assert json_response(result, 200)["redirect"] == "/"
    refute get_session(result, :confirmed_at)
    refute get_session(result, :reauth_target)
  end

  test "auth secrets are filtered from request logs" do
    filtered =
      Phoenix.Logger.filter_values(%{
        "code" => "recovery-secret",
        "token" => "invite-secret",
        "credential" => %{"response" => "webauthn-secret"},
        "username" => "ada"
      })

    assert filtered["code"] == "[FILTERED]"
    assert filtered["token"] == "[FILTERED]"
    assert filtered["credential"] == "[FILTERED]"
    assert filtered["username"] == "ada"
  end
end
