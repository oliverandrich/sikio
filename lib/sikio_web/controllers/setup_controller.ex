# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SetupController do
  @moduledoc """
  Exchanges the operator's setup code for an authorization proof in the session.

  This is a controller action, not a LiveView event, because a LiveView cannot write the session.
  The session binds the claim to the browser that submitted the code.

  The setup code is not stored. The session stores the proof, which expires after ten minutes.
  """
  use SikioWeb, :controller

  alias Ithibati.Identity.Instance
  alias Sikio.AuthRateLimiter
  alias SikioWeb.AuthRateLimit

  def create(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    {limit, seconds} = AuthRateLimiter.budget(:setup)

    case AuthRateLimiter.check(AuthRateLimit.key(conn, :setup), limit, seconds) do
      :ok -> exchange(conn, params["setup_code"])
      {:error, retry_after} -> too_many(conn, retry_after)
    end
  end

  # Every refused code gets the same message. Distinct messages would help a guesser.
  defp exchange(conn, code) when is_binary(code) do
    case Instance.authorize_code(code) do
      {:ok, proof} ->
        conn
        |> put_session(:setup_authorization, proof)
        |> redirect(to: ~p"/setup")

      _refused ->
        refuse(conn)
    end
  end

  defp exchange(conn, _missing) do
    conn
    |> put_flash(:error, gettext("Enter the code the operator gave you."))
    |> redirect(to: ~p"/setup")
  end

  defp refuse(conn) do
    conn
    |> put_flash(:error, gettext("That code was not accepted. Ask the operator for another."))
    |> redirect(to: ~p"/setup")
  end

  # Shows the wait in seconds, so a user who mistyped knows when to retry.
  # The response says nothing about the submitted code.
  defp too_many(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> put_flash(
      :error,
      gettext("Too many attempts. Try again in %{seconds} seconds.", seconds: retry_after)
    )
    |> redirect(to: ~p"/setup")
  end
end
