# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Admin do
  @moduledoc """
  The `on_mount` hook of the administrator pages. They live in the member live_session and
  declare it with `on_mount/1`, so it runs after Ithibati's gate has assigned `current_account`.

  It reads the account the gate loaded for this mount. Every `Sikio.Accounts` function checks
  the role in its own query as well, so a role revoked meanwhile changes nothing.
  """
  use SikioWeb, :verified_routes

  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  use Gettext, backend: SikioWeb.Gettext

  def on_mount(:require_admin, _params, _session, socket) do
    if socket.assigns.current_account.admin,
      do: {:cont, socket},
      else: {:halt, turn_away(socket)}
  end

  @doc "Sends a member to the settings with a message."
  def turn_away(socket) do
    socket
    |> put_flash(:error, gettext("Only administrators can open this page."))
    |> redirect(to: ~p"/account/settings")
  end
end
