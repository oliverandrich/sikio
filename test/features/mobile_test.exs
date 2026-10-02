# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MobileTest do
  @moduledoc """
  The reader at phone width, where only a browser can say what lies where.

  Below `lg` the main navigation is a bar along the bottom and the library narrows through a row
  of chips. The player panel floats above that bar rather than over it.
  """
  use SikioWeb.FeatureCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  setup %{session: session} do
    account = signed_up(session, "ada")

    for {document, url} <- [
          {podcast(), "https://example.org/rss"},
          {youtube(), youtube_feed_url()}
        ] do
      {:ok, preview} = Parser.parse(document, url)
      {:ok, _} = Library.subscribe(account, preview)
    end

    %{entries: Map.new(Library.entries(account), &{&1.feed.kind, &1})}
  end

  feature "the navigation is a bar along the bottom and chips narrow the list", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(500, 900)
    |> open("/")
    |> execute_script(gap_below("#main-navigation"), fn gap -> assert gap == 0 end)
    |> click(css("#chip-sources summary"))
    |> click(css("#chip-source-#{entries.podcast.feed_id}"))
    # `refute_has/2` asks once, so the patch is waited for by the chip it marks.
    |> assert_has(css(~s|#chip-source-#{entries.podcast.feed_id}[aria-current="page"]|))
    |> assert_has(css("#entries article", text: entries.podcast.title))
    |> refute_has(css("#entries article", text: entries.youtube.title))
  end

  feature "the player panel floats above the bar, not over it", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(500, 900)
    |> open("/library/#{entries.podcast.id}")
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel audio"))
    |> execute_script(
      """
      return document.querySelector('#player-panel').getBoundingClientRect().bottom <=
             document.querySelector('#main-navigation').getBoundingClientRect().top
      """,
      fn above -> assert above, "the panel covers the navigation" end
    )
  end

  defp gap_below(selector),
    do:
      "return Math.round(innerHeight - document.querySelector('#{selector}').getBoundingClientRect().bottom)"
end
