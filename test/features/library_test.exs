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

  # The search folds away behind the magnifier. Opened, the field takes the keyboard, so typing
  # j or k searches rather than moves; Escape clears it and folds it away again.
  feature "the magnifier opens a search that narrows the list", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/")
    |> assert_has(css("#entries article", count: 25))
    |> refute_has(css("#search-input"))
    |> click(css("#toggle-search"))
    |> assert_has(css("#search-input"))
    |> execute_script("return document.activeElement.id", fn id -> assert id == "search-input" end)
    |> fill_in(css("#search-input"), with: "Episode 17")
    |> assert_has(css("#entries article", count: 1))
    |> send_keys([:escape])
    |> assert_has(css("#entries article", count: 25))
    |> refute_has(css("#search-input"))
    |> execute_script("return document.activeElement.id", fn id ->
      assert id == "toggle-search"
    end)
  end

  # f opens the search from the keyboard, beside j, k and m, and the f is not typed into it.
  feature "f opens the search and puts the cursor in it", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/")
    |> assert_has(css("#entries article", count: 25))
    |> send_keys(["f"])
    |> assert_has(css("#search-input"))
    |> execute_script("return [document.activeElement.id, document.activeElement.value]", fn
      [id, value] ->
        assert id == "search-input"
        assert value == ""
    end)
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
