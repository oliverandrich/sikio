# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ExtensionReturn do
  @moduledoc """
  Remembers the extension's connect page for a signed-out visit, so the sign-in returns there.

  The extension's sign-in window opens the page with its parameters. Gate sends a signed-out
  visitor to `/login`, and `SikioWeb.Auth.authenticate/2` reads the path back with
  `returning/1`. Signing in clears the session, so it reads the path first.
  """
  import Plug.Conn

  # The extension's parameters take some 300 bytes. A longer query would crowd the 4 KB cookie.
  @max_bytes 1000

  def init(opts), do: opts

  # The time lets the sign-in ignore a visit left behind; see `returning/1`.
  def call(%{assigns: %{current_account: nil}} = conn, _opts) do
    path = conn.request_path <> "?" <> conn.query_string

    if byte_size(path) <= @max_bytes,
      do: put_session(conn, :extension_return, {System.system_time(:second), path}),
      else: conn
  end

  def call(conn, _opts), do: conn

  @doc """
  Returns the remembered connect page when it was visited within the last ten minutes, else nil.

  An abandoned visit must not redirect a later ordinary sign-in.
  """
  def returning({at, path}) when is_integer(at) and is_binary(path) do
    if System.system_time(:second) - at <= 600, do: path
  end

  def returning(_remembered), do: nil
end
