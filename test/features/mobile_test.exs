# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MobileTest do
  @moduledoc """
  The reader at phone width, where only a browser can say what lies where.

  Below `lg` the main navigation is a tab bar along the bottom, and the Library tab leads to
  every place. The player panel floats above that bar rather than over it.
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

  # A phone moves through tabs at the bottom, from the Library into a source and back.
  feature "the tabs lead through the library and back", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(390, 844)
    |> open("/new")
    |> execute_script(gap_below("#main-navigation"), fn gap -> assert gap == 0 end)
    |> click(css("#tab-library"))
    |> assert_has(css(~s|#tab-library[aria-current="page"]|))
    |> click(css("#places-sources a", text: "Small Hours"))
    |> assert_has(css("#library-heading", text: "Small Hours"))
    |> assert_has(css("#entries article", text: entries.podcast.title))
    |> refute_has(css("#entries article", text: entries.youtube.title))
    |> click(css("#nav-back"))
    |> assert_has(css("#places-views"))
  end

  # On a phone the filters fold away behind a button. Once open they stay open while the reader
  # moves between them, however the page was reached.
  feature "the filters stay open while the reader changes them", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(500, 900)
    |> open("/feeds/#{entries.podcast.feed_id}/completed")
    |> assert_has(css("#filter-status-all"))
    |> click(css("#filter-status-all"))
    |> assert_has(css(~s|#filter-status-all[aria-current="true"]|))
    |> assert_has(css("#filter-status-new"))
    |> assert_has(css(~s|#toggle-filters[aria-expanded="true"]|))
  end

  feature "the player panel floats above the bar, not over it", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(500, 900)
    |> open(item_path(entries.podcast))
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel [data-audio-face]"))
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
