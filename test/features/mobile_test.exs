# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MobileTest do
  @moduledoc """
  The reader at phone width, where only a browser can say what lies where.

  Below `lg` the main navigation is a tab bar along the bottom, and the Library tab leads to
  every place. The player sits in the item that plays and floats above that bar elsewhere.
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

    %{account: account, entries: Map.new(Library.entries(account), &{&1.feed.kind, &1})}
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

  # An item names itself in the bar once its title has scrolled away, and the bar leads back to
  # the list it was opened from.
  feature "an item leads back to its list from the bar", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(390, 844)
    |> open("/new")
    |> click(css("#entries a", text: entries.podcast.title))
    |> assert_has(css("#nav-back", text: "New"))
    |> refute_has(css("#app-header[data-shrunk]"))
    |> execute_script("""
    document.getElementById('item-detail').style.paddingBottom = '2000px'
    window.scrollTo(0, 600)
    """)
    |> assert_has(css("#app-header[data-shrunk]"))
    |> click(css("#nav-back"))
    |> assert_has(css("#entries article", text: entries.youtube.title))
    |> refute_has(css("#nav-back"))
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

  # As on YouTube: the video spans the screen at the top of its item and stays under the bar while
  # the notes scroll beneath it. Its frame here is a page of Sikio's own and it has no picture, so
  # nothing is asked of an instance.
  feature "a video plays across the top of its item and stays there", context do
    %{session: session, account: account} = context
    {:ok, preview} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, subscription} = Library.subscribe(account, preview)
    [video] = Library.entries(account, %{"source" => to_string(subscription.feed_id)})
    notes = String.duplicate("<p>Something worth reading while it plays.</p>", 40)

    Sikio.Repo.update!(
      Ecto.Changeset.change(video,
        embed_url: "/robots.txt",
        image_url: nil,
        description: notes,
        description_format: :html
      )
    )

    session
    |> resize_window(390, 844)
    |> open(item_path(video))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-panel[data-place="pinned"] iframe|))
    |> execute_script(edges(), fn [left, width, top] ->
      assert left == 0
      assert width == 0, "the video spans the screen"
      assert top == "slot", "the video lies on its slot"
    end)
    |> execute_script("window.scrollTo(0, 600); return window.scrollY", fn y -> assert y > 0 end)
    |> then(fn session ->
      script = """
      const panel = document.getElementById('player-panel').getBoundingClientRect()
      return Math.round(panel.top) === Math.round(document.getElementById('masthead').getBoundingClientRect().bottom) &&
             getComputedStyle(document.getElementById('player-panel')).visibility === 'visible'
      """

      assert {:ok, _} = retry(fn -> holds(session, script) end), "the video stays under the bar"
      session
    end)
  end

  # Held sideways the video fits between the bars and passes under them as the page scrolls. Cut
  # off at the foot from the start, it still stays under the top bar once scrolled up to it.
  feature "a video fits a phone held sideways", context do
    %{session: session, account: account} = context
    {:ok, preview} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, subscription} = Library.subscribe(account, preview)
    [video] = Library.entries(account, %{"source" => to_string(subscription.feed_id)})
    notes = String.duplicate("<p>Something worth reading while it plays.</p>", 40)

    Sikio.Repo.update!(
      Ecto.Changeset.change(video,
        embed_url: "/robots.txt",
        image_url: nil,
        description: notes,
        description_format: :html
      )
    )

    session
    |> resize_window(844, 390)
    |> open(item_path(video))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-panel[data-place="pinned"] iframe|))
    |> execute_script(
      """
      const box = id => document.getElementById(id).getBoundingClientRect()
      const room = innerHeight - box('masthead').height - box('main-navigation').height
      const tabs = box('main-navigation')
      const hit = document.elementFromPoint(tabs.left + tabs.width / 2, tabs.top + tabs.height / 2)
      return [Math.round(box('player-panel').height) <= Math.round(room),
              document.getElementById('main-navigation').contains(hit)]
      """,
      fn [fits, tabs] ->
        assert fits, "the video fits between the bars"
        assert tabs, "the tab bar stays above the video"
      end
    )
    # Just past the bar, while most of the slot is still in view.
    |> execute_script("""
    const slot = document.getElementById('player-slot').getBoundingClientRect().top
    window.scrollTo(0, scrollY + slot - document.getElementById('masthead').getBoundingClientRect().bottom + 40)
    """)
    |> then(fn session ->
      script = """
      return Math.round(document.getElementById('player-panel').getBoundingClientRect().top) ===
             Math.round(document.getElementById('masthead').getBoundingClientRect().bottom)
      """

      assert {:ok, _} = retry(fn -> holds(session, script) end), "the video stays under the bar"
      session
    end)
  end

  # Audio needs no watching. It sits in its card and scrolls away with it.
  feature "audio plays in its card and scrolls with it", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(390, 844)
    |> open(item_path(entries.podcast))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
    |> execute_script(edges(), fn [_left, _width, top] -> assert top == "slot" end)
  end

  # Away from its item the player is a capsule above the tab bar: what plays, play or pause, and
  # a way to close it. Its title leads back to the item, where the player is whole again.
  feature "away from its item the player is a capsule above the tabs", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(390, 844)
    |> open(item_path(entries.podcast))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-panel[data-place="pinned"]|))
    |> click(css("#tab-new"))
    |> assert_has(css(~s|#player-panel[data-place="floating"] #capsule-play|))
    |> assert_has(css("#capsule-art"))
    |> assert_has(css("#close-player"))
    |> assert_has(css("#player-panel .player-title", text: entries.podcast.title))
    |> assert_has(css("#player-panel [data-audio-face]", visible: false))
    |> execute_script(
      """
      const panel = document.getElementById('player-panel').getBoundingClientRect()
      const bar = document.getElementById('main-navigation').getBoundingClientRect()
      return [Math.round(panel.left), Math.round(document.documentElement.clientWidth - panel.right),
              Math.round(bar.top - panel.bottom), Math.round(panel.height)]
      """,
      fn [left, right, above, height] ->
        assert {left, right, above} == {8, 8, 8}
        assert height <= 72, "a capsule, not a card"
      end
    )
    # Its button drives the player as the keyboard does.
    |> execute_script("""
    window.sikioCommands = []
    document.querySelector('#player-panel [phx-hook=MediaPlayer]')
      .addEventListener('sikio:command', event => window.sikioCommands.push(event.detail.name))
    """)
    |> click(css("#capsule-play"))
    |> execute_script("return window.sikioCommands", fn names -> assert names == ["toggle"] end)
    |> click(css("#player-panel .player-title"))
    |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
  end

  # A video keeps playing in the capsule, small.
  feature "a video plays on in the capsule", context do
    %{session: session, account: account} = context
    {:ok, preview} = Parser.parse(peertube(), peertube_feed_url())
    {:ok, subscription} = Library.subscribe(account, preview)
    [video] = Library.entries(account, %{"source" => to_string(subscription.feed_id)})
    Sikio.Repo.update!(Ecto.Changeset.change(video, embed_url: "/robots.txt", image_url: nil))

    session
    |> resize_window(390, 844)
    |> open(item_path(video))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-panel[data-place="pinned"] iframe|))
    |> click(css("#tab-new"))
    |> assert_has(css(~s|#player-panel[data-place="floating"] iframe|))
    |> refute_has(css("#capsule-art"))
    |> execute_script(
      "const b = document.querySelector('#player-panel iframe').getBoundingClientRect(); return [Math.round(b.width), Math.round(b.height)]",
      fn size -> assert size == [96, 54] end
    )
  end

  # The panel's left edge, how much narrower than the screen it is, and whether its top is the
  # slot's.
  defp edges do
    """
    const panel = document.getElementById('player-panel').getBoundingClientRect()
    const slot = document.getElementById('player-slot').getBoundingClientRect()
    return [Math.round(panel.left), Math.round(document.documentElement.clientWidth - panel.width),
            Math.abs(panel.top - slot.top) <= 1 ? 'slot' : panel.top - slot.top]
    """
  end

  defp holds(session, script) do
    execute_script(session, script, fn value -> Process.put(:holds, value) end)
    if Process.delete(:holds) == true, do: {:ok, session}, else: {:error, :not_yet}
  end

  defp gap_below(selector),
    do:
      "return Math.round(innerHeight - document.querySelector('#{selector}').getBoundingClientRect().bottom)"
end
