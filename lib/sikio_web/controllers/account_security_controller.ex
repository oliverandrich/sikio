defmodule SikioWeb.AccountSecurityController do
  @moduledoc "Account security mutations, authenticated again on every request."
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

  def confirm(conn, %{"purpose" => purpose}) when purpose in ["passkeys", "recovery-codes"] do
    conn
    |> put_session(:reauth_target, "/account/" <> purpose)
    |> redirect(to: ~p"/account/verify")
  end

  def confirm(conn, _params), do: conn |> send_resp(404, "Not Found")

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
