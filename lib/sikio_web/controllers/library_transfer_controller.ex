# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryTransferController do
  @moduledoc "Sends the current account's library as a JSON download for another instance."
  use SikioWeb, :controller

  alias Sikio.Library.Transfer

  plug Ithibati.Web.Gate, {:require_account, to: "/login"}

  def export(conn, _params) do
    conn
    # The file holds the account's library, so no cache may store it.
    |> put_resp_header("cache-control", "no-store")
    |> send_download({:binary, Jason.encode!(Transfer.export(conn.assigns.current_account))},
      filename: "sikio-library.json",
      content_type: "application/json"
    )
  end
end
