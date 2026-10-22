# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ExtensionController do
  @moduledoc "The connect page's sign-in link: remembers the page and opens the sign-in."
  use SikioWeb, :controller

  alias SikioWeb.ExtensionReturn

  def sign_in(conn, %{"return" => path}) when is_binary(path) do
    case ExtensionReturn.remember(conn, path) do
      {:ok, conn} -> redirect(conn, to: ~p"/login")
      :error -> send_resp(conn, 404, "Not Found")
    end
  end

  def sign_in(conn, _params), do: send_resp(conn, 404, "Not Found")
end
