# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SessionController do
  @moduledoc "Signing out is a plain request, because a LiveView cannot clear a session cookie."
  use SikioWeb, :controller

  alias Ithibati.Web.Gate

  def sign_out(conn, _params), do: conn |> Gate.log_out() |> redirect(to: "/login")

  @doc """
  Renders the recovery codes once and deletes them from the session.

  This is a controller action, because a LiveView cannot delete a session key.
  Without the deletion a reload would show the codes again.
  """
  def recovery_codes(conn, _params) do
    case get_session(conn, :recovery_codes) do
      nil -> redirect(conn, to: "/")
      codes -> conn |> delete_session(:recovery_codes) |> render(:recovery_codes, codes: codes)
    end
  end
end
