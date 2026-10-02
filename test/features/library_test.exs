# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryTest do
  @moduledoc """
  The library's list in a real browser, where scrolling is what asks for more.

  `Phoenix.LiveViewTest` can send the event a viewport sends, but not whether the browser sends
  it when the list's end comes into view.
  """
  use SikioWeb.FeatureCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  setup %{session: session} do
    account = signed_up(session, "ada")
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")

    entries =
      for n <- 1..40,
          do: %{hd(preview.entries) | external_id: "episode-#{n}", title: "Episode #{n}"}

    {:ok, _} = Library.subscribe(account, %{preview | entries: entries})
    :ok
  end

  feature "the list loads the next batch when its end comes into view", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/")
    |> assert_has(css("#entries article", count: 25))
    |> execute_script("document.querySelector('#entries article:last-child').scrollIntoView()")
    |> assert_has(css("#entries article", count: 40))
  end
end
