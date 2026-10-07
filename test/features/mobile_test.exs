# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MobileTest do
  @moduledoc """
  The reader at phone width, where only a browser can say what lies where.

  Below `lg` the main navigation is a tab bar along the bottom, and the Library tab leads to
  every place. The player sits in the item that plays and floats above that bar elsewhere.
  """
  use SikioWeb.FeatureCase

  import Ecto.Query, only: [where: 2]
  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  setup %{session: session} do
    account = signed_in(session, "ada")

    for {document, url} <- [
          {podcast(), "https://example.org/rss"},
          {youtube(), youtube_feed_url()}
        ] do
      {:ok, preview} = Parser.parse(document, url)
      {:ok, _} = Library.subscribe(account, preview)
    end

    %{account: account, entries: Map.new(Library.entries(account), &{&1.feed.kind, &1})}
  end

  # An iPhone keeps its status bar above the page and its home indicator beneath it. The page
  # reads both through `--safe-top` and `--safe-bottom`, which Chrome never fills; set here to an
  # iPhone's, the bars must clear them. The tab bar follows Apple's 49 points above the indicator.
  # Held sideways the notch is beside the page, read through `--safe-left` and `--safe-right`.
  feature "the bars clear an iPhone's status bar, home indicator and notch", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(500, 900)
    |> open(item_path(entries.podcast))
    |> execute_script(
      "document.documentElement.style.cssText = '--safe-top: 47px; --safe-bottom: 34px'"
    )
    |> click(css("#start-playback"))
    |> click(css("#tab-inbox"))
    |> assert_has(css(~s|#player-panel[data-place="floating"]|))
    |> execute_script(
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
    |> resize_window(844, 390)
    |> open("/inbox")
    |> execute_script(
      "document.documentElement.style.cssText = '--safe-left: 47px; --safe-right: 47px'"
    )
    |> execute_script(
      """
      const left = s => document.querySelector(s).getBoundingClientRect().left
      return [left('#library-heading'), left('#masthead a'), left('#tab-inbox')].map(Math.round)
      """,
      fn lefts ->
        assert Enum.all?(lefts, &(&1 >= 47)), "something sits under the notch: #{inspect(lefts)}"
      end
    )
  end

  # Held sideways a phone has little height. The title stands in the bar from the start and the
  # list's head closes up, so the list gets most of the screen. The large heading stays for
  # screen readers.
  @sessions [
    [
      capabilities:
        put_in(Wallaby.Chrome.default_capabilities(), [:chromeOptions, :mobileEmulation], %{
          deviceMetrics: %{width: 844, height: 390, pixelRatio: 1}
        })
    ]
  ]
  feature "held sideways the list gets most of the height", %{session: session} do
    session
    |> open("/inbox")
    |> assert_has(css("#entries article", count: 2))
    |> execute_script(
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

  # On a phone the filters fold away behind a button. Once open they stay open while the reader
  # moves between them, however the page was reached.
  feature "the filters stay open while the reader changes them", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(500, 900)
    |> open("/feeds/#{entries.podcast.feed_id}/history")
    |> assert_has(css("#filter-status-all"))
    |> click(css("#filter-status-all"))
    |> assert_has(css(~s|#filter-status-all[aria-current="true"]|))
    |> assert_has(css("#filter-status-inbox"))
    |> assert_has(css(~s|#toggle-filters[aria-expanded="true"]|))
  end

  # As on YouTube: the video spans the screen at the top of its item and stays under the bar while
  # the notes scroll beneath it. Its frame here is a page of Sikio's own and it has no picture, so
  # nothing is asked of an instance.
  feature "a video plays across the top of its item and stays there", context do
    %{session: session, account: account} = context
    video = video_with_notes(account)

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
    video = video_with_notes(account)

    # The window leaves 247 pixels, so the poster lies under the tab bar: pressed where it is.
    session
    |> resize_window(844, 390)
    |> open(item_path(video))
    |> execute_script("document.getElementById('start-playback').click()")
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

  # The pinned player takes its width from the page script rather than from `anchor-size()`.
  # Safari measured its container before that width was known, laid the buttons out for a
  # narrow one and shifted them as the time changed. A width written on the panel is known from
  # the start.
  feature "the pinned player has its slot's width from the start", context do
    %{session: session, entries: entries} = context

    session
    |> resize_window(500, 900)
    |> open(item_path(entries.podcast))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
    |> execute_script(
      """
      const panel = document.getElementById('player-panel')
      return [panel.style.width, Math.round(document.getElementById('player-slot').getBoundingClientRect().width) + 'px']
      """,
      fn [written, slot] -> assert written == slot end
    )
  end

  # An episode's controls sit in its card and stay under the bar as the notes scroll, rather than
  # passing half under it. Before anything plays the card shows the player's likeness, which
  # stays there too, so starting it changes nothing about where it is.
  feature "audio stays under the bar as its notes scroll, before and after it plays", context do
    %{session: session, entries: entries} = context

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

    session
    |> resize_window(390, 844)
    |> open(item_path(entries.podcast))
    |> assert_has(css("#player-slot #audio-cue"))
    |> execute_script(scrolled_past_the_slot)
    |> then(fn session ->
      script = under_the_bar.("player-slot")
      assert {:ok, _} = retry(fn -> holds(session, script) end), "the card's player stays"
      session
    end)
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
    |> execute_script(edges(), fn [_left, _width, top] -> assert top == "slot" end)
    # Starting patches the detail, which takes the padding with it.
    |> execute_script(scrolled_past_the_slot)
    |> then(fn session ->
      script = under_the_bar.("player-panel")
      assert {:ok, _} = retry(fn -> holds(session, script) end), "the controls stay under the bar"
      session
    end)
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
    |> click(css("#tab-inbox"))
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
    video = video_with_notes(account)

    session
    |> resize_window(390, 844)
    |> open(item_path(video))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-panel[data-place="pinned"] iframe|))
    |> click(css("#tab-inbox"))
    |> assert_has(css(~s|#player-panel[data-place="floating"] iframe|))
    |> gone(css("#capsule-art"))
    |> execute_script(
      "const b = document.querySelector('#player-panel iframe').getBoundingClientRect(); return [Math.round(b.width), Math.round(b.height)]",
      fn size -> assert size == [96, 54] end
    )
  end

  # Publishers paste bare addresses as link text. A word longer than the screen breaks inside the
  # notes rather than widening the page.
  @sessions [
    [
      capabilities:
        put_in(Wallaby.Chrome.default_capabilities(), [:chromeOptions, :mobileEmulation], %{
          deviceMetrics: %{width: 390, height: 844, pixelRatio: 1}
        })
    ]
  ]
  feature "a long link in the notes does not widen the page", context do
    %{session: session, entries: entries} = context
    url = "https://example.org/?ref=" <> String.duplicate("a1b2c3d4e5", 20)

    Sikio.Repo.update_all(
      where(Sikio.Feeds.Entry, id: ^entries.podcast.id),
      set: [description: ~s|<p>Read <a href="#{url}">#{url}</a></p>|, description_format: :html]
    )

    session
    |> open(item_path(entries.podcast))
    |> assert_has(css("#item-notes a"))
    |> execute_script(
      "return [document.documentElement.scrollWidth, document.documentElement.clientWidth]",
      fn [scroll, client] -> assert scroll <= client end
    )
  end

  # A PeerTube video whose frame is a page of Sikio's own, without a picture, with notes to scroll.
  defp video_with_notes(account) do
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
end
