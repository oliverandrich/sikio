# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.OPMLController do
  @moduledoc "Sends the current account's subscriptions as an OPML download."
  use SikioWeb, :controller

  alias Sikio.Library.OPML

  plug Ithibati.Web.Gate, {:require_account, to: "/login"}

  def export(conn, _params) do
    conn
    # The file lists the account's subscriptions, so no cache may store it.
    |> put_resp_header("cache-control", "no-store")
    |> send_download({:binary, OPML.export(conn.assigns.current_account)},
      filename: "sikio-subscriptions.opml",
      content_type: "text/xml"
    )
  end
end
