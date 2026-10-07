# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PicturesFeatureTest do
  @moduledoc """
  Source images requested by the browser and fetched in the server's request process.
  """
  use SikioWeb.FeatureCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  # `nobody_answers/1` stubs every outgoing request with a 404, so the fallback image is served.
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
