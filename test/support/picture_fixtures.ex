# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.PictureFixtures do
  @moduledoc false

  alias Sikio.Feeds.HTTP

  def jpeg, do: <<0xFF, 0xD8, 0xFF, 0xE0>> <> "jpeg body"
  def png, do: <<0x89, "PNG\r\n", 0x1A, "\n">> <> "png body"

  @doc """
  Answers every picture request through the feed stub, by path.

  `routes` maps a path to `{content_type, body}`, or is a function from a path to that pair or
  `nil`. Anything else is a 404. Each request is reported to the test as `{:fetched, path}`.
  """
  def serving(routes) do
    owner = self()
    route = if is_map(routes), do: &Map.get(routes, &1), else: routes

    Req.Test.stub(HTTP, fn conn ->
      send(owner, {:fetched, conn.request_path})

      case route.(conn.request_path) do
        {type, body} ->
          conn |> Plug.Conn.put_resp_content_type(type, nil) |> Plug.Conn.send_resp(200, body)

        nil ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)
  end
end
