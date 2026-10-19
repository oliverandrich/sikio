# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PicturesFeatureTest do
  @moduledoc """
  Source images requested by the browser and fetched in the server's request process.
  """
  use SikioWeb.PlaywrightCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  # `nobody_answers/1` stubs every outgoing request with a 404, so the fallback image is served.
  test "a picture nobody can fetch falls back to the mark of its kind", %{conn: conn} do
    account = signed_in(conn, "ada")
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, _} = Library.subscribe(account, preview)

    conn
    |> open("/inbox")
    |> assert_has(~s|img[src^="/pictures/"]|)
    |> script(
      """
      const src = document.querySelector('img[src^="/pictures/"]').getAttribute('src')
      return fetch(src).then(response => [response.status, new URL(response.url).pathname])
      """,
      fn [status, path] ->
        assert status == 200
        assert path == "/images/kind-audio.svg"
      end
    )
  end
end
