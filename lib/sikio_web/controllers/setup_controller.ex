# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SetupController do
  @moduledoc """
  Exchanges the operator's code for the proof that opens the first-account form.

  A plain form post rather than a live event, because only a request that owns the connection
  may write to the session, and the session is where the proof belongs: it ties the claim to the
  browser the code was typed into.

  The code is read once and never kept. What is stored is the proof, which expires on its own.
  """
  use SikioWeb, :controller

  alias Ithibati.Identity.Instance
  alias Sikio.AuthRateLimiter
  alias SikioWeb.AuthRateLimit

  def create(conn, params) do
    conn = put_resp_header(conn, "cache-control", "no-store")
    {limit, seconds} = AuthRateLimit.budget(:setup)

    case AuthRateLimiter.check(AuthRateLimit.key(conn, :setup), limit, seconds) do
      :ok -> exchange(conn, params["setup_code"])
      {:error, retry_after} -> too_many(conn, retry_after)
    end
  end

  # One answer for a code that is wrong, spent, rotated or never existed. Saying which would tell
  # a guesser whether they are close.
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

  # The wait is told, because somebody who mistyped deserves to know when to try again. Nothing
  # about the code is told, because the budget is spent by guesses as readily as by mistakes.
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
