# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AccountSecurityController do
  @moduledoc """
  Account security mutations.

  Regenerating recovery codes requires a reauthentication within the last five minutes.
  """
  use SikioWeb, :controller

  alias Ithibati.Identity.Passkeys
  alias Ithibati.Identity.RecoveryCodes
  alias Ithibati.Web.Gate
  alias SikioWeb.Reauth

  plug :require_confirmation when action in [:regenerate_codes]

  defp require_confirmation(conn, _opts) do
    if Reauth.confirmed?(conn),
      do: conn,
      else: conn |> redirect(to: ~p"/account/confirm/recovery-codes") |> halt()
  end

  # The extension's connect page carries its parameters in the query, so it returns there.
  def confirm(conn, %{"purpose" => "extension", "return" => path}) do
    if Reauth.extension_connect?(path),
      do: conn |> put_session(:reauth_target, path) |> redirect(to: ~p"/account/verify"),
      else: send_resp(conn, 404, "Not Found")
  end

  def confirm(conn, %{"purpose" => purpose}) do
    case Reauth.target(purpose) do
      {:ok, path} ->
        conn |> put_session(:reauth_target, path) |> redirect(to: ~p"/account/verify")

      :error ->
        send_resp(conn, 404, "Not Found")
    end
  end

  def sign_out_all(conn, _params), do: conn |> Gate.log_out_all() |> redirect(to: ~p"/login")

  def rename_passkey(conn, %{"id" => id, "label" => label}) do
    conn
    |> passkey_result(
      Passkeys.rename_key(conn.assigns.current_account, id, label),
      gettext("Passkey renamed.")
    )
  end

  def delete_passkey(conn, %{"id" => id}) do
    conn
    |> passkey_result(
      Passkeys.delete_key(conn.assigns.current_account, id),
      gettext("Passkey removed.")
    )
  end

  defp passkey_result(conn, {:ok, _key}, message),
    do: conn |> put_flash(:info, message) |> redirect(to: ~p"/account/passkeys")

  defp passkey_result(conn, {:error, :last_key}, _message),
    do:
      conn
      |> put_flash(:error, gettext("Add another passkey before removing your last one."))
      |> redirect(to: ~p"/account/passkeys")

  defp passkey_result(conn, {:error, :not_found}, _message),
    do:
      conn
      |> put_flash(:error, gettext("This passkey is no longer available."))
      |> redirect(to: ~p"/account/passkeys")

  def regenerate_codes(conn, %{"confirm" => "true"}) do
    codes = RecoveryCodes.regenerate(conn.assigns.current_account)
    conn |> put_session(:recovery_codes, codes) |> redirect(to: ~p"/recovery-codes")
  end

  def regenerate_codes(conn, _params) do
    conn
    |> put_flash(
      :error,
      gettext("Please confirm that your previous recovery codes will stop working.")
    )
    |> redirect(to: ~p"/account/recovery-codes")
  end
end
