# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ExtensionTokenController do
  @moduledoc """
  Exchanges an extension's authorization code and PKCE verifier for a token.

  The request comes from the extension, without a session or a CSRF token. The code and the
  verifier together prove that it started the connection. Errors follow RFC 6749.
  """
  use SikioWeb, :controller

  alias Sikio.Extensions
  alias SikioWeb.AuthRateLimit

  # Each exchange costs a transaction, so exchanges count per client address.
  plug :limited

  defp limited(conn, _opts), do: AuthRateLimit.limit(conn, conn, :api_address)

  def create(conn, %{"code" => code, "code_verifier" => verifier, "redirect_uri" => uri}) do
    case Extensions.exchange(code, verifier, uri) do
      {:ok, token} -> json(conn, %{token: token})
      {:error, :invalid} -> invalid(conn)
    end
  end

  def create(conn, _params), do: invalid(conn)

  defp invalid(conn), do: conn |> put_status(400) |> json(%{error: "invalid_grant"})
end
