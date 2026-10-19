# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MobileTest do
  @moduledoc """
  The layout at phone width, measured in Chrome.

  Below `lg` the main navigation is a bottom tab bar. The Library tab links to every list.
  The player is pinned in the playing item's detail and floats above the tab bar elsewhere.
  """
  use SikioWeb.PlaywrightCase

  import Ecto.Query, only: [where: 2]
  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  setup %{conn: conn} do
    account = signed_in(conn, "ada")

    for {document, url} <- [
          {podcast(), "https://example.org/rss"},
          {youtube(), youtube_feed_url()}
        ] do
      {:ok, preview} = Parser.parse(document, url)
      {:ok, _} = Library.subscribe(account, preview)
    end

    %{account: account, entries: Map.new(Library.entries(account), &{&1.feed.kind, &1})}
  end

  # iOS places the status bar above the page and the home indicator below it.
  # The page reads both from `--safe-top` and `--safe-bottom`. Chrome leaves them unset.
  # The test sets iPhone values, and the bars must clear them.
  # The tab bar is Apple's 49 points tall above the indicator.
  # In landscape the notch is at the side, read from `--safe-left` and `--safe-right`.
  test "the bars clear an iPhone's status bar, home indicator and notch", context do
    %{conn: conn, entries: entries} = context

    conn
    |> resize(500, 900)
    |> open(item_path(entries.podcast))
    |> script("document.documentElement.style.cssText = '--safe-top: 47px; --safe-bottom: 34px'")
    |> click("#start-playback")
    |> click("#tab-inbox")
    |> assert_has(~s|#player-panel[data-place="floating"]|)
    |> script(
      """
      const box = id => document.getElementById(id).getBoundingClientRect()
      const labels = [...document.querySelectorAll('#main-navigation a span')]
        .map(label => label.getBoundingClientRect().bottom)
      return [Math.round(innerHeight - box('main-navigation').top),
              Math.max(...labels) <= innerHeight - 34,
              Math.round(box('masthead').top + parseFloat(getComputedStyle(document.getElementById('masthead')).paddingTop)),
              Math.round(box('main-navigation').top - box('player-panel').bottom)]
      """,
      fn [bar, labels_clear, masthead_content, capsule_gap] ->
        assert bar == 49 + 34, "the tab bar is 49 above the indicator's 34, not #{bar}"
        assert labels_clear, "a label sits on the home indicator"
        assert masthead_content >= 47, "the bar's content sits under the status bar"
        assert capsule_gap == 8, "the capsule keeps its distance from the tab bar"
      end
    )
    |> resize(844, 390)
    |> open("/inbox")
    |> script("document.documentElement.style.cssText = '--safe-left: 47px; --safe-right: 47px'")
    |> script(
      """
      const left = s => document.querySelector(s).getBoundingClientRect().left
      return [left('#library-heading'), left('#masthead a'), left('#tab-inbox')].map(Math.round)
      """,
      fn lefts ->
        assert Enum.all?(lefts, &(&1 >= 47)), "something sits under the notch: #{inspect(lefts)}"
      end
    )
  end

  # A phone in landscape has little height. The bar shows the title from the start.
  # The list head is compact, so the list gets most of the screen.
  # The large heading takes no height but stays for screen readers.
  @tag browser_context_opts: phone(844, 390)
  test "held sideways the list gets most of the height", %{conn: conn} do
    conn
    |> open("/inbox")
    |> assert_has("#entries article", count: 2)
    |> script(
      """
      const top = s => document.querySelector(s).getBoundingClientRect().top
      const heading = document.getElementById('library-heading')
      return [Math.round(top('#entries') - document.getElementById('masthead').getBoundingClientRect().bottom),
              getComputedStyle(document.getElementById('nav-title')).opacity,
              heading.textContent.trim(), heading.getBoundingClientRect().height <= 1]
      """,
      fn [head, title, heading, hidden] ->
        assert head <= 56, "the list's head takes #{head}px"
        assert title == "1", "the bar names the place"
        assert heading == "Inbox", "the heading stays for screen readers"
        assert hidden, "the large heading takes no room"
      end
    )
  end

  # On a phone the filters are behind a toggle button. After a filter change they stay open.
  test "the filters stay open while the reader changes them", context do
    %{conn: conn, entries: entries} = context

    conn
    |> resize(500, 900)
    |> open("/feeds/#{entries.podcast.feed_id}/history")
    |> assert_has("#filter-status-all")
    |> click("#filter-status-all")
    |> assert_has(~s|#filter-status-all[aria-current="true"]|)
    |> assert_has("#filter-status-open")
    |> assert_has(~s|#toggle-filters[aria-expanded="true"]|)
  end

  # The video spans the screen width at the top of its item, as on YouTube.
  # It stays below the bar while the notes scroll.
  # It has no image. The browser blocks its instance, so no request leaves the test.
  test "a video plays across the top of its item and stays there", context do
    %{conn: conn, account: account} = context
    video = video_with_notes(conn, account)

    conn
    |> resize(390, 844)
    |> open(item_path(video))
    |> click("#start-playback")
    |> assert_has(~s|#player-panel[data-place="pinned"] video|)
    |> script(edges(), fn [left, width, top] ->
      assert left == 0
      assert width == 0, "the video spans the screen"
      assert top == "slot", "the video lies on its slot"
    end)
    |> script("window.scrollTo(0, 600); return window.scrollY", fn y -> assert y > 0 end)
    |> eventually(
      """
      const panel = document.getElementById('player-panel').getBoundingClientRect()
      return Math.round(panel.top) === Math.round(document.getElementById('masthead').getBoundingClientRect().bottom) &&
             getComputedStyle(document.getElementById('player-panel')).visibility === 'visible'
      """,
      message: "the video stays under the bar"
    )
  end

  # In landscape the video's height fits between the bars, and it scrolls under them.
  # Initially its bottom is under the tab bar. Scrolled up, it stays below the top bar.
  test "a video fits a phone held sideways", context do
    %{conn: conn, account: account} = context
    video = video_with_notes(conn, account)

    # The window leaves 247 px, so the play button lies under the tab bar.
    # The test clicks it by script.
    conn
    |> resize(844, 390)
    |> open(item_path(video))
    |> script("document.getElementById('start-playback').click()")
    |> assert_has(~s|#player-panel[data-place="pinned"] video|)
    |> script(
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
    # Scrolls just past the bar, with most of the slot still visible.
    |> script("""
    const slot = document.getElementById('player-slot').getBoundingClientRect().top
    window.scrollTo(0, scrollY + slot - document.getElementById('masthead').getBoundingClientRect().bottom + 40)
    """)
    |> eventually(
      """
      return Math.round(document.getElementById('player-panel').getBoundingClientRect().top) ===
             Math.round(document.getElementById('masthead').getBoundingClientRect().bottom)
      """,
      message: "the video stays under the bar"
    )
  end

  # The page script sets the pinned player's width instead of `anchor-size()`.
  # Safari measured the container before that width was known.
  # It laid out the buttons for a narrow container and shifted them as the time changed.
  # An inline width is known from the start.
  test "the pinned player has its slot's width from the start", context do
    %{conn: conn, entries: entries} = context

    conn
    |> resize(500, 900)
    |> open(item_path(entries.podcast))
    |> click("#start-playback")
    |> assert_has(~s|#player-panel[data-place="pinned"] [data-audio-face]|)
    |> script(
      """
      const panel = document.getElementById('player-panel')
      return [panel.style.width, Math.round(document.getElementById('player-slot').getBoundingClientRect().width) + 'px']
      """,
      fn [written, slot] -> assert written == slot end
    )
  end

  # An episode's controls sit in its card and stay below the bar while the notes scroll.
  # They do not pass halfway under it.
  # Before playback the card shows the `#audio-cue` placeholder, which also stays below the bar.
  # Starting playback puts the panel on the same slot.
  test "audio stays under the bar as its notes scroll, before and after it plays", context do
    %{conn: conn, entries: entries} = context

    under_the_bar = fn id ->
      """
      const box = document.getElementById('#{id}')
      return Math.round(box.getBoundingClientRect().top) ===
               Math.round(document.getElementById('masthead').getBoundingClientRect().bottom) &&
             getComputedStyle(box).visibility === 'visible'
      """
    end

    scrolled_past_the_slot = """
    document.getElementById('item-detail').style.paddingBottom = '2000px'
    const slot = document.getElementById('player-slot').getBoundingClientRect().top
    window.scrollTo(0, scrollY + slot - document.getElementById('masthead').getBoundingClientRect().bottom + 60)
    """

    conn
    |> resize(390, 844)
    |> open(item_path(entries.podcast))
    |> assert_has("#player-slot #audio-cue")
    |> script(scrolled_past_the_slot)
    |> eventually(under_the_bar.("player-slot"), message: "the card's player stays")
    |> click("#start-playback")
    |> assert_has(~s|#player-panel[data-place="pinned"] [data-audio-face]|)
    # Starting playback patches the detail and drops the padding, so the page jumps.
    # The panel follows the slot after the intersection observer fires, one frame later.
    |> eventually("return (() => { #{edges()} })()[2] === 'slot'",
      message: "the panel lies on its slot"
    )
    |> script(scrolled_past_the_slot)
    |> eventually(under_the_bar.("player-panel"), message: "the controls stay under the bar")
  end

  # Away from its item the player is a capsule above the tab bar.
  # It shows the title, play/pause and close.
  # The title links back to the item and its full player.
  test "away from its item the player is a capsule above the tabs", context do
    %{conn: conn, entries: entries} = context

    conn
    |> resize(390, 844)
    |> open(item_path(entries.podcast))
    |> click("#start-playback")
    |> assert_has(~s|#player-panel[data-place="pinned"]|)
    |> click("#tab-inbox")
    |> assert_has(~s|#player-panel[data-place="floating"] #capsule-play|)
    |> assert_has("#capsule-art")
    |> assert_has("#close-player")
    |> assert_has("#player-panel .player-title", text: entries.podcast.title)
    |> assert_hidden("#player-panel [data-audio-face]")
    |> script(
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
    # The capsule button sends the `toggle` command, the same one the keyboard sends.
    |> script("""
    window.sikioCommands = []
    document.querySelector('#player-panel [phx-hook=MediaPlayer]')
      .addEventListener('sikio:command', event => window.sikioCommands.push(event.detail.name))
    """)
    |> click("#capsule-play")
    |> script("return window.sikioCommands", fn names -> assert names == ["toggle"] end)
    |> click("#player-panel .player-title")
    |> assert_has(~s|#player-panel[data-place="pinned"] [data-audio-face]|)
  end

  # In the capsule a video keeps its picture, shown at 96 by 54 px.
  test "a video stays in the capsule at 96 by 54", context do
    %{conn: conn, account: account} = context
    video = video_with_notes(conn, account)

    conn
    |> resize(390, 844)
    |> open(item_path(video))
    |> click("#start-playback")
    |> assert_has(~s|#player-panel[data-place="pinned"] video|)
    |> click("#tab-inbox")
    |> assert_has(~s|#player-panel[data-place="floating"] video|)
    |> refute_has("#capsule-art")
    |> script(
      "const b = document.querySelector('#player-panel video').getBoundingClientRect(); return [Math.round(b.width), Math.round(b.height)]",
      fn size -> assert size == [96, 54] end
    )
  end

  # Publishers use bare URLs as link text. A word wider than the screen must not widen the page.
  @tag browser_context_opts: phone(390, 844)
  test "a long link in the notes does not widen the page", context do
    %{conn: conn, entries: entries} = context
    url = "https://example.org/?ref=" <> String.duplicate("a1b2c3d4e5", 20)

    Sikio.Repo.update_all(
      where(Sikio.Feeds.Entry, id: ^entries.podcast.id),
      set: [description: ~s|<p>Read <a href="#{url}">#{url}</a></p>|, description_format: :html]
    )

    conn
    |> open(item_path(entries.podcast))
    |> assert_has("#item-notes a")
    |> script(
      "return [document.documentElement.scrollWidth, document.documentElement.clientWidth]",
      fn [scroll, client] -> assert scroll <= client end
    )
  end

  # Returns the panel's left edge, the screen width minus the panel width,
  # and `'slot'` when the panel top matches the slot top.
  defp edges do
    """
    const panel = document.getElementById('player-panel').getBoundingClientRect()
    const slot = document.getElementById('player-slot').getBoundingClientRect()
    return [Math.round(panel.left), Math.round(document.documentElement.clientWidth - panel.width),
            Math.abs(panel.top - slot.top) <= 1 ? 'slot' : panel.top - slot.top]
    """
  end
end
