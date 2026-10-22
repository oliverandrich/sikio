# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ExtensionReturn do
  @moduledoc """
  Brings the extension's sign-in window back to its connect page after a sign-in.

  Signed out, the connect page links to `/extension/sign-in`. Only that click remembers the page,
  so a crafted link alone redirects no later sign-in. `SikioWeb.Auth.authenticate/2` reads the
  page back with `returning/1` within ten minutes. Signing in clears the session, so it reads the
  path first.

  That sign-in used a passkey or a recovery code a moment ago. `confirm/2` records it as the
  confirmation for connecting only, so it unlocks no other page that `SikioWeb.Reauth` guards.
  """
  import Plug.Conn

  alias SikioWeb.Reauth

  # The extension's parameters take some 300 bytes. A longer query would crowd the 4 KB cookie.
  @max_bytes 1000
  @return_seconds 600

  @doc "Remembers `path`, the connect page with its query, unless it is too long or elsewhere."
  def remember(conn, path) do
    if Reauth.extension_connect?(path) and byte_size(path) <= @max_bytes,
      do: {:ok, put_session(conn, :extension_return, {System.system_time(:second), path})},
      else: :error
  end

  @doc "Returns the remembered connect page when remembered within ten minutes, else nil."
  def returning({at, path}) when is_integer(at) and is_binary(path) do
    if System.system_time(:second) - at <= @return_seconds and Reauth.extension_connect?(path),
      do: path
  end

  def returning(_remembered), do: nil

  @doc "Records the sign-in as the confirmation for connecting `account`."
  def confirm(conn, %{id: id}),
    do: put_session(conn, :extension_confirmed, {id, System.system_time(:second)})

  @doc "Returns whether `session` holds that confirmation for `account` from the last five minutes."
  def confirmed?(%{"extension_confirmed" => {id, at}}, %{id: id}), do: Reauth.fresh?(at)

  def confirmed?(_session, _account), do: false
end
