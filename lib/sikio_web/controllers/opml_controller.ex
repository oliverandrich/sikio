defmodule SikioWeb.OPMLController do
  @moduledoc "Downloads this account's sources as an OPML file."
  use SikioWeb, :controller

  alias Sikio.Library.OPML

  plug Ithibati.Web.Gate, {:require_account, to: "/login"}

  def export(conn, _params) do
    conn
    # The file names every source somebody subscribed to, so it is not something a shared cache
    # should keep a copy of.
    |> put_resp_header("cache-control", "no-store")
    |> send_download({:binary, OPML.export(conn.assigns.current_account)},
      filename: "sikio-subscriptions.opml",
      content_type: "text/xml"
    )
  end
end
