# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PictureController do
  use SikioWeb, :controller

  alias Sikio.Pictures

  # A week in the browser. The picture behind an address does not change once it was fetched.
  @max_age 604_800

  def show(conn, %{"ref" => reference}) do
    case SikioWeb.Pictures.verify(reference) do
      {:ok, {urls, fallback}} -> answer(conn, Pictures.fetch(urls), fallback)
      :error -> send_resp(conn, 404, "")
    end
  end

  # The type is one of four raster types read from the bytes, never the publisher's header.
  # The path is the cache directory joined with a hash, never a name from the request.
  # sobelow_skip ["XSS.ContentType", "Traversal.SendFile"]
  defp answer(conn, {:ok, %{type: type, path: path}}, _fallback) do
    conn
    |> put_resp_content_type(type, nil)
    |> put_resp_header("cache-control", "private, max-age=#{@max_age}")
    |> send_file(200, path)
  end

  defp answer(conn, :error, fallback), do: redirect(conn, to: fallback)
end
