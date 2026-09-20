# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AccountSecurityTest do
  use SikioWeb.ConnCase

  alias Ithibati.Identity.Passkeys
  alias Ithibati.Identity.RecoveryCodes
  alias Sikio.Accounts.User
  alias Sikio.Repo
  alias SikioWeb.Auth

  defp attrs,
    do: %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)}

  setup do
    {:ok, signed} =
      Auth.register(Plug.Test.init_test_session(build_conn(), %{}), attrs(), "ada", %{})

    account = Repo.get_by!(User, username: "ada")

    session =
      get_session(signed)
      |> Map.put("confirmed_at", System.system_time(:second))
      |> Map.put("confirmed_account_id", account.id)

    %{conn: Plug.Test.init_test_session(build_conn(), session), account: account}
  end

  test "header offers a username menu and both protected account pages", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)
    assert html =~ "id=\"user-menu\""
    assert html =~ "href=\"/account/passkeys\""
    assert html =~ "href=\"/account/recovery-codes\""
    assert conn |> get("/account/passkeys") |> html_response(200) =~ "Manage passkeys"
    assert conn |> get("/account/recovery-codes") |> html_response(200) =~ "12"
  end

  test "anonymous requests cannot read or change account security" do
    for path <- ["/account/passkeys", "/account/recovery-codes"] do
      assert build_conn() |> get(path) |> redirected_to() == "/login"
    end

    assert build_conn()
           |> post("/account/recovery-codes", %{"confirm" => "true"})
           |> redirected_to() == "/login"

    assert build_conn()
           |> patch("/account/passkeys/unknown", %{"label" => "Bad"})
           |> redirected_to() == "/login"

    assert build_conn() |> delete("/account/passkeys/unknown") |> redirected_to() == "/login"
  end

  test "renaming and deletion are ownership scoped and preserve the last key", %{
    conn: conn,
    account: account
  } do
    [key] = Passkeys.list_keys(account)
    renamed = patch(conn, "/account/passkeys/#{key.id}", %{"label" => "Laptop"})
    assert redirected_to(renamed) == "/account/passkeys"
    assert [%{label: "Laptop"}] = Passkeys.list_keys(account)
    delete(conn, "/account/passkeys/#{key.id}")
    assert length(Passkeys.list_keys(account)) == 1
    other = Repo.insert!(User.changeset(%User{}, %{username: "grace"}))
    {:ok, foreign} = Passkeys.add_key(other, attrs())
    patch(conn, "/account/passkeys/#{foreign.id}", %{"label" => "Stolen"})
    delete(conn, "/account/passkeys/#{foreign.id}")
    assert [%{label: "Passkey"}] = Passkeys.list_keys(other)
    {:ok, spare} = Passkeys.add_key(account, attrs())
    delete(conn, "/account/passkeys/#{spare.id}")
    assert [%{id: id}] = Passkeys.list_keys(account)
    assert id == key.id
  end

  test "regeneration needs confirmation, invalidates old codes and shows the new batch once", %{
    conn: conn,
    account: account
  } do
    [old | _] = RecoveryCodes.regenerate(account)
    rejected = post(conn, "/account/recovery-codes", %{})
    assert redirected_to(rejected) == "/account/recovery-codes"
    assert {:ok, _, _} = RecoveryCodes.redeem(old)
    [old | _] = RecoveryCodes.regenerate(account)
    generated = post(conn, "/account/recovery-codes", %{"confirm" => "true"})
    assert redirected_to(generated) == "/recovery-codes"
    assert {:error, :invalid} = RecoveryCodes.redeem(old)
    [fresh | _] = get_session(generated, :recovery_codes)
    shown = generated |> recycle() |> get("/recovery-codes")
    assert html_response(shown, 200) =~ fresh
    refute get_session(shown, :recovery_codes)
    assert shown |> recycle() |> get("/recovery-codes") |> redirected_to() == "/"
  end

  test "enrollment uses the signed-in account and rechecks it on completion", %{
    conn: conn,
    account: account
  } do
    signed = Plug.Conn.assign(conn, :current_account, account)

    assert {:ok, ^account} =
             Auth.registration_subject(signed, %{"intent" => "add_passkey", "username" => "grace"})

    assert {:error, :authentication_required} =
             Auth.registration_subject(build_conn(), %{"intent" => "add_passkey"})

    assert {:error, :authentication_required} = Auth.register(build_conn(), attrs(), account, %{})
    other = Repo.insert!(User.changeset(%User{}, %{username: "grace"}))

    assert {:error, :authentication_required} =
             Auth.register(Plug.Conn.assign(conn, :current_account, other), attrs(), account, %{})

    assert {:ok, result} = Auth.register(signed, attrs(), account, %{"label" => "Phone"})
    assert json_response(result, 200)["redirect"] == "/account/passkeys"
    assert Enum.any?(Passkeys.list_keys(account), &(&1.label == "Phone"))
  end
end
