# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PicturesFeatureTest do
  @moduledoc """
  A source's picture as the browser asks for it, from the server's own request process.
  """
  use SikioWeb.FeatureCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  # Nobody's server is asked in a test, so the picture cannot be had and its fallback stands in.
  feature "a picture nobody can fetch falls back to the mark of its kind", %{session: session} do
    account = signed_in(session, "ada")
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, _} = Library.subscribe(account, preview)

    session
    |> open("/inbox")
    |> assert_has(css(~s|img[src^="/pictures/"]|, minimum: 1))
    |> execute_script(
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
