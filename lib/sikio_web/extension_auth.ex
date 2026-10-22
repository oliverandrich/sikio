# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ExtensionAuth do
  @moduledoc """
  Authenticates the browser extension's API requests by their bearer token (RFC 6750).

  A valid token assigns `current_account`. Each request counts against the account's `api`
  budget in `Sikio.AuthRateLimiter`, since a lookup fetches the page's sources. A request
  without a valid token counts against the same budget per client address, so nobody guesses
  tokens without limit.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Sikio.Extensions
  alias SikioWeb.AuthRateLimit

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer(conn),
         {:ok, account} <- Extensions.authenticate(token) do
      conn |> assign(:current_account, account) |> limited(account)
    else
      _ -> conn |> limited(conn) |> refused()
    end
  end

  # The scheme is case-insensitive.
  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      [header] ->
        case Regex.run(~r/\Abearer\s+(\S+)\s*\z/i, header) do
          [_header, token] -> {:ok, token}
          nil -> :error
        end

      _ ->
        :error
    end
  end

  # `subject` is the account, or the connection for its client address.
  defp limited(conn, subject), do: AuthRateLimit.limit(conn, subject, :api)

  defp refused(%{halted: true} = conn), do: conn

  defp refused(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_status(401)
    |> json(%{error: "invalid_token"})
    |> halt()
  end
end
