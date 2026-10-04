# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlayerTest do
  @moduledoc """
  The player in a real browser, which is the only place it exists.

  `Phoenix.LiveViewTest` can render the dock and answer its events, but it cannot say whether the
  audio element survives navigation, whether the panel stays outside the view that gets swapped, or
  what the page looks like once it is compacted. Those are the properties the dock exists for.

  The audio itself never loads here, because nothing serves it. That is deliberate: what is being
  checked is that the element is never replaced, not somebody else's media server. Whether sound
  keeps coming out of a real speaker is a question for a real device, and it has its own bean.
  """
  use SikioWeb.FeatureCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias SikioWeb.PlayerDockLive

  @notes "#item-notes, #item-no-notes"

  setup %{session: session} do
    account = signed_up(session, "ada")
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, _subscription} = Library.subscribe(account, preview)
    [entry] = Library.entries(account)

    %{account: account, entry: entry}
  end

  feature "the audio element itself survives navigating between pages", context do
    %{session: session, account: account, entry: entry} = context

    session
    |> open("/all")
    |> click(css("#play-#{entry.id}"))
    |> click(css("#start-playback"))
    # Pinned to the detail the panel leaves the title to it, so the player says what it plays.
    |> assert_has(css(~s|#player-control[data-entry-id="#{entry.id}"]|))
    |> assert_has(css("#player-panel [data-audio-face]"))
    |> mark_player()
    |> click(css("#subscriptions-heading"))
    |> assert_has(css("h1", text: "Make room"))
    # From lg the panel folds into the sidebar's bar there, which keeps the audio mounted but
    # out of sight. What this asks is that it is the same element.
    |> assert_has(css("#player-panel audio", visible: false))
    |> assert_same_player()

    assert Library.entry(account, entry.id).playback.session_id
  end

  # On a phone the playing player lies on the card's own. Two players for the one episode would
  # disagree, so the card's gives way while its episode plays.
  feature "on a phone the card's player gives way to the playing one", context do
    %{session: session, entry: entry} = context

    session
    |> resize_window(500, 900)
    |> open(item_path(entry))
    |> assert_has(css("#audio-cue"))
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel [data-audio-face]"))
    |> assert_has(css("#audio-cue", visible: false))
  end

  # The browser's own media session names the episode, for the lock screen and media keys, and
  # forgets it once the player closes.
  feature "the system's controls name what plays", context do
    %{session: session, entry: entry} = context
    named = "return navigator.mediaSession.metadata && navigator.mediaSession.metadata.title"

    session
    |> open(item_path(entry))
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel [data-audio-face]"))
    |> execute_script(named, fn title -> assert title == entry.title end)
    |> execute_script(
      "return navigator.mediaSession.metadata.artwork[0].src",
      fn src -> assert src =~ "/pictures/" end
    )
    |> press("close-player")
    |> then(fn session ->
      assert {:ok, _} =
               retry(fn -> holds(session, "return navigator.mediaSession.metadata === null") end)

      session
    end)
  end

  # An item that ends hands on to the next in the queue, as long as playing on is on. Nothing is
  # served to play here, so the audio's own end event is what the test sends.
  feature "an ended item plays on with the queue", context do
    %{session: session, account: account, entry: entry} = context
    {:ok, preview} = Parser.parse(podcast("Next up"), feed_url("next"))
    {:ok, subscription} = Library.subscribe(account, preview)
    [following] = Library.entries(account, %{"source" => to_string(subscription.feed_id)})
    {:ok, _} = Sikio.Playback.enqueue(account, following.id, :last)

    session
    |> open(item_path(entry))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-control[data-entry-id="#{entry.id}"]|))
    |> execute_script(
      "document.querySelector('#player-panel audio').dispatchEvent(new Event('ended'))"
    )
    |> assert_has(css(~s|#player-control[data-entry-id="#{following.id}"]|))
  end

  feature "the player survives a dropped and restored socket", context do
    %{session: session, account: account, entry: entry} = context

    session
    |> open(item_path(entry))
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel [data-audio-face]"))
    |> mark_player()
    |> drop_socket(account)
    |> assert_has(css("body[data-rejoined]"))
    |> assert_has(css("#player-panel [data-audio-face]"))
    |> assert_same_player()

    assert Library.entry(account, entry.id).playback.session_id
  end

  # The room is for the floating panel, which only a narrow screen has.
  feature "closing the player gives the page its scroll room back", context do
    %{session: session, entry: entry} = context

    session
    |> resize_window(500, 900)
    |> open(item_path(entry))
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel"))
    |> click(css("#tab-inbox"))
    |> assert_has(css(~s|#player-panel[data-place="floating"]|))
    |> execute_script(padding(), fn padding -> refute padding == "0px" end)
    |> press("close-player")

    # `refute_has/2` asks once and fails on what is still on screen, so it cannot wait for the
    # round trip that closing takes. Waiting for the value this test is named after is the wait,
    # and the panel being gone is what puts it back to zero.
    assert {:ok, _} = retry(fn -> settled(session) end)
    refute_has(session, css("#player-panel"))
  end

  describe "from lg, the player's place" do
    setup %{account: account} do
      {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
      {:ok, _} = Library.subscribe(account, preview)
      [video] = Enum.filter(Library.entries(account), &(&1.feed.kind == :youtube))
      %{video: video}
    end

    # A video spans its card from edge to edge, as it spans a phone's screen. Its place is
    # measured before it plays, so nothing is asked of YouTube.
    feature "a video's place spans its card", context do
      %{session: session, video: video} = context

      session
      |> resize_window(1280, 900)
      |> open(item_path(video))
      |> assert_has(css("#player-slot #start-playback"))
      |> execute_script(flush("#player-slot", "#item-detail article"), fn flush ->
        assert flush
      end)
    end

    # The player sits where the detail shows it: at the card's head, above the title and notes.
    feature "is in the detail that shows what plays, above its title", context do
      %{session: session, account: account, entry: entry} = context

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> click(css("#start-playback"))
      |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
      |> execute_script(within("#player-panel", "#item-detail"), fn inside -> assert inside end)
      # The detail around it names the source and the title, and choosing another item puts it
      # away, so it needs no heading of its own and no button to close it.
      |> assert_has(css("#player-panel .player-heading", visible: false))
      |> assert_has(css("#close-player", visible: false))
      # It sits on the detail's card, not on the column around it.
      |> execute_script(flush("#player-panel", "#player-slot"), fn flush -> assert flush end)
      # The medium first, then the text about it: the title opens the reading column, on the
      # notes' own edge.
      |> then(fn session ->
        assert {:ok, _} =
                 retry(fn -> holds(session, below("#item-detail h2", "#player-panel")) end)

        session
      end)
      |> execute_script(
        """
        const box = s => document.querySelector(s).getBoundingClientRect()
        return [Math.round(box('#item-detail h2').left), Math.round(box('#item-notes, #item-no-notes').left),
                box(arguments[0]).top >= box('#item-detail h2').bottom]
        """,
        [@notes],
        fn [title, notes, below] ->
          assert title == notes, "the title stands on the notes' edge"
          assert below, "the notes follow the title"
        end
      )
      # A saved place patches the detail and the dock. Neither patch may take the placement away,
      # not even for the frame until it is worked out again: that frame is a flicker.
      |> execute_script("""
      window.sikioLost = []
      const watch = (id, name) => new MutationObserver(() => {
        if (!document.querySelector(id).hasAttribute(name)) window.sikioLost.push(name)
      }).observe(document.querySelector(id), {attributes: true, attributeFilter: [name, 'style']})
      watch('#player-slot', 'data-pinned')
      watch('#player-panel', 'data-place')
      """)
      |> saved_at(account, entry, 30)
      |> assert_has(css("#playback-status", text: "62 min left"))
      |> then(fn session ->
        # The dock's status is hidden while pinned, and webdriver reads only visible text.
        status = "#player-panel .player-status"
        script = "return document.querySelector('#{status}').textContent.includes('0:30')"
        assert {:ok, _} = retry(fn -> holds(session, script) end)
        session
      end)
      |> execute_script("return window.sikioLost", fn lost -> assert lost == [] end)
      # Whatever changes the player's height, the slot follows, so the notes are never under it.
      |> execute_script(
        "document.querySelector('#player-panel [data-audio-face]').style.height = '300px'"
      )
      |> then(fn session ->
        assert {:ok, _} = retry(fn -> holds(session, below(@notes, "#player-panel")) end)
        session
      end)
    end

    # The card shows the player itself before anything loads. Letting go of its bar starts the
    # dock's player there, which lies exactly over it.
    feature "the card's player starts where it is dragged to and is covered without a jump",
            context do
      %{session: session, account: account, entry: entry} = context

      box =
        "const b = document.querySelector(arguments[0]).getBoundingClientRect(); return [b.left, b.top, b.width, b.height].map(Math.round)"

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> refute_has(css("#player-panel"))
      |> execute_script(box, ["#audio-cue"], fn cue -> Process.put(:cue, cue) end)
      |> execute_script("""
      const seek = document.querySelector('#audio-cue [data-audio-seek]')
      seek.value = '600'
      seek.dispatchEvent(new Event('input', {bubbles: true}))
      seek.dispatchEvent(new Event('change', {bubbles: true}))
      """)
      |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-seek][value="600"]|))
      |> assert_has(css("#audio-cue", visible: false))
      |> then(fn session ->
        cue = Process.delete(:cue)
        script = "#{box}.join(',') === '#{Enum.join(cue, ",")}'"
        # The panel's face, not the panel: the message line beneath it is empty and folded away.
        assert {:ok, _} =
                 retry(fn ->
                   holds(
                     session,
                     String.replace(script, "arguments[0]", "'#player-panel [data-audio-face]'")
                   )
                 end)

        session
      end)

      assert Library.entry(account, entry.id).playback.position == 600.0
    end

    # A chapter starts the item at its place; once it plays, another chapter moves the player.
    feature "a chapter starts the item there and later moves the player", context do
      %{session: session, account: account} = context
      notes = "<p>Worum es geht.</p><p>0:00 Intro<br>1:58 Akkus<br>4:51 Solar</p>"

      body =
        String.replace(
          podcast("Chapters"),
          ~r|<content:encoded>.*?</content:encoded>|s,
          "<content:encoded><![CDATA[#{notes}]]></content:encoded>"
        )

      {:ok, preview} = Parser.parse(body, feed_url("chapters"))
      {:ok, subscription} = Library.subscribe(account, preview)

      [entry] =
        Library.entries(account, %{"source" => to_string(subscription.feed_id)})

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> click(css("#item-chapters li:nth-child(2) button"))
      |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-seek][value="118"]|))
      # The audio never loads here, and what an element without media does with a place depends
      # on when its failed load ends. That the player moves the audio is the node tests' to show;
      # this one shows that the click reaches the player that plays, with the chapter's place.
      |> execute_script("""
      window.sought = []
      document.querySelector("#player-control [phx-hook='MediaPlayer']")
        .addEventListener('sikio:seek', event => window.sought.push(event.detail.position))
      """)
      |> click(css("#item-chapters li:nth-child(3) button"))
      |> then(fn session ->
        assert {:ok, _} = retry(fn -> holds(session, "return window.sought.join() === '291'") end)
        session
      end)
    end

    # Sikio's own controls act on the audio element underneath: dragging moves it on letting go,
    # the skips jump, the speed steps on. The audio itself never loads here, so the element's
    # own answers are what is checked.
    feature "the controls drag, skip and change the speed", context do
      %{session: session, entry: entry} = context

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> click(css("#start-playback"))
      |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
      |> execute_script(
        """
        const audio = document.querySelector('#player-panel audio')
        const seek = document.querySelector('#player-panel [data-audio-seek]')
        const text = name => document.querySelector(`#player-panel [data-audio-${name}]`).textContent.trim()
        const moves = []
        seek.value = '120'
        seek.dispatchEvent(new Event('input', {bubbles: true}))
        moves.push([text('elapsed'), audio.currentTime])
        seek.dispatchEvent(new Event('change', {bubbles: true}))
        moves.push([text('elapsed'), audio.currentTime])
        document.querySelector('#player-panel [data-audio-skip="30"]').click()
        moves.push(audio.currentTime)
        document.querySelector('#player-panel [data-audio-skip="-15"]').click()
        moves.push(audio.currentTime)
        document.querySelector('#player-panel [data-audio-speed]').click()
        moves.push([audio.playbackRate, text('speed')])
        return moves
        """,
        fn [dragging, released, forward, back, speed] ->
          assert dragging == ["2:00", 0]
          assert released == ["2:00", 120]
          assert forward == 150
          assert back == 135
          assert speed == [1.25, "1.25×"]
        end
      )
    end

    # The page keeps the keyboard and drives the player through it: p plays and pauses, the
    # arrows skip. Space stays the page's. The library's keys stay the library's, wherever the focus is.
    feature "the page's keys drive the player", context do
      %{session: session, account: account, entry: entry} = context

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> click(css("#start-playback"))
      |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
      |> execute_script(
        """
        window.commands = []
        document.querySelector("#player-control [phx-hook='MediaPlayer']")
          .addEventListener('sikio:command', event => window.commands.push(event.detail.name))
        return document.activeElement.closest('#player-panel') === null
        """,
        fn outside -> assert outside, "the started player leaves the keyboard to the page" end
      )
      |> send_keys(["p", " ", :right_arrow])
      |> then(fn session ->
        assert {:ok, _} =
                 retry(fn ->
                   holds(session, "return window.commands.join() === 'toggle,skip'")
                 end)

        session
      end)
      |> send_keys(["m"])
      |> assert_has(css("#mark-new"))

      assert Library.entry(account, entry.id).playback.status == :heard
    end

    # Before anything plays, p starts the open item as its play button does.
    feature "p starts the open item", context do
      %{session: session, entry: entry} = context

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> assert_has(css("#start-playback"))
      |> refute_has(css("#player-control[data-entry-id]"))
      |> send_keys(["p"])
      |> assert_has(css(~s|#player-control[data-entry-id="#{entry.id}"]|))
    end

    # A click into a video's frame takes the keyboard where the page cannot hear it. The page takes
    # it back and gives it to the panel. A frame of the page's own stands in for the video's.
    feature "takes the keyboard back from a frame in the player", context do
      %{session: session, entry: entry} = context

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> click(css("#start-playback"))
      |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
      |> execute_script("""
      const frame = document.createElement('iframe')
      frame.id = 'stand-in'
      frame.srcdoc = '<button id="inside" style="width:100%;height:100%">inside</button>'
      frame.style.cssText = 'width: 300px; height: 120px'
      document.getElementById('player-panel').prepend(frame)
      """)
      |> click(css("#stand-in"))
      |> then(fn session ->
        script = "return document.activeElement && document.activeElement.id === 'player-panel'"
        assert {:ok, _} = retry(fn -> holds(session, script) end)
        session
      end)
    end

    # The detail scrolls in its own column, and the pinned player moves with its slot.
    feature "moves with the detail as it scrolls", context do
      %{session: session, entry: entry} = context

      session
      |> resize_window(1280, 320)
      |> open(item_path(entry))
      |> click(css("#start-playback"))
      |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
      # Settled first, so nothing still pending places the player after the scroll.
      |> execute_script(
        """
        const frame = () => new Promise(resolve => requestAnimationFrame(resolve))
        return frame().then(frame).then(frame).then(() => {
          const detail = document.getElementById('item-detail')
          detail.scrollTop = 60
          return detail.scrollTop
        })
        """,
        fn top -> assert top > 0, "the detail has something to scroll" end
      )
      # Two frames after the scroll, with nothing else changing in between.
      |> execute_script(
        """
        const frame = () => new Promise(resolve => requestAnimationFrame(resolve))
        return frame().then(frame).then(() => {
          const a = document.getElementById('player-panel').getBoundingClientRect(),
                b = document.getElementById('player-slot').getBoundingClientRect()
          return Math.round(a.top - b.top)
        })
        """,
        fn offset -> assert offset == 0, "the player lies on its slot" end
      )
    end

    # The mini player's title shows what plays in the list on screen when it holds it. The list
    # stays; before, the title led to an address without one and the list became all items.
    feature "its title shows what plays without leaving the list", context do
      %{session: session, account: account} = context
      {:ok, preview} = Parser.parse(podcast("Two Parts"), feed_url("two"))

      entries =
        for n <- 1..2,
            do: %{
              hd(preview.entries)
              | external_id: "two-#{n}",
                title: "Part #{n}",
                published_at: DateTime.add(hd(preview.entries).published_at, -n, :day)
            }

      {:ok, subscription} = Library.subscribe(account, %{preview | entries: entries})
      [first, second] = Library.entries(account, %{"source" => to_string(subscription.feed_id)})

      # All items: playing moves an item from the inbox into the queue.
      session
      |> resize_window(1280, 900)
      |> open("/all")
      |> click(css("#entries-#{first.id} a"))
      |> click(css("#start-playback"))
      |> assert_has(css(~s|#player-control[data-entry-id="#{first.id}"]|))
      |> click(css("#entries-#{second.id} a"))
      |> assert_has(css(~s|#player-panel[data-place="compact"] .player-title|))
      |> click(css("#player-panel .player-title"))
      |> assert_has(css("#item-detail h2", text: "Part 1"))
      |> assert_has(css("#library-heading", text: "All items"))
      |> then(fn session ->
        assert current_path(session) == "/all/#{first.id}-part-1"
        session
      end)
    end

    # Starting one item after another hands the player on each time, and the last one still
    # closes. Each start waits for the previous player to save its place.
    feature "starts one item after another and still closes", context do
      %{session: session, account: account} = context
      {:ok, preview} = Parser.parse(podcast(), feed_url("three"))

      entries =
        for n <- 1..3,
            do: %{hd(preview.entries) | external_id: "three-#{n}", title: "Part #{n}"}

      {:ok, _} = Library.subscribe(account, %{preview | entries: entries})

      ids =
        account
        |> Library.entries()
        |> Enum.filter(&String.starts_with?(&1.title, "Part"))
        |> Enum.map(& &1.id)

      session = session |> resize_window(1280, 900) |> open("/all")

      # Through the list, as a reader moves: the page and its player are never loaded again.
      for id <- ids do
        session
        |> click(css("#entries-#{id} a"))
        |> assert_has(css(~s|#item-detail[data-entry-id="#{id}"]|))
        |> click(css("#start-playback"))
        |> assert_has(css(~s|#player-control[data-entry-id="#{id}"]|))
      end

      session
      |> click(css("#entries-#{hd(ids)} a"))
      |> assert_has(css(~s|#player-panel[data-place="compact"]|))
      |> click(css("#close-player"))
      # refute_has fails at once while the panel is still there; a count of none waits for it.
      |> assert_has(css("#player-panel", count: 0))
    end

    # Playback is global and selection is not. When they disagree the notes get the room, and the
    # player floats at the bottom left, twice the sidebar's width, over the foot of the sidebar and
    # the list, which both keep room to scroll out from under it. On a page without a detail it
    # still says what plays and can pause it.
    feature "floats at the bottom left when the detail shows something else", context do
      %{session: session, account: account, entry: entry, video: video} = context

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> click(css("#start-playback"))
      |> assert_has(css("#player-panel [data-audio-face]"))
      |> mark_player()
      |> click(css("#play-#{video.id}"))
      |> assert_has(css(~s|#player-panel[data-place="compact"] [data-audio-play]|))
      |> execute_script(
        """
        const panel = document.getElementById('player-panel').getBoundingClientRect()
        const sidebar = document.querySelector('header:has(#main-navigation)').getBoundingClientRect()
        const room = parseFloat(getComputedStyle(document.getElementById('list-pane')).paddingBottom)
        return [panel.left - sidebar.left, Math.round(window.innerHeight - panel.bottom),
                Math.round(panel.width), room >= panel.height]
        """,
        fn [left, bottom, width, room] ->
          assert left == 12
          assert bottom == 16
          assert width == 480
          assert room, "the list keeps room to scroll out from under the player"
        end
      )
      |> click(css("#subscriptions-heading"))
      |> assert_has(css(~s|#player-panel[data-place="compact"]|))
      |> assert_same_player()
      # Nothing is served to play here, so the audio's own play event is what the test sends.
      |> assert_has(css("#player-panel [data-audio-play] .audio-icon-play"))
      |> execute_script(
        "document.querySelector('#player-panel audio').dispatchEvent(new Event('play'))"
      )
      |> assert_has(css("#player-panel [data-audio-play] .audio-icon-pause"))
      |> assert_has(css("#player-panel [data-audio-play] .audio-icon-play", visible: false))
      |> saved_at(account, entry, 30)
      # A saved place patches the panel. The button has to keep saying pause through it.
      |> then(fn session ->
        script =
          "return document.querySelector('#player-panel .player-status').textContent.includes('0:30')"

        assert {:ok, _} = retry(fn -> holds(session, script) end)
        session
      end)
      |> assert_has(css("#player-panel [data-audio-play] .audio-icon-pause"))
    end
  end

  # A button in the floating panel, pressed where it is rather than at a point on the screen. The
  # panel stands on the bar at the foot and grows upwards when its message line fills, here with
  # the audio that is never served; a click aimed a moment before can land on the seek bar then.
  # What these tests ask is what the button does, not where it was.
  defp press(session, id), do: execute_script(session, "document.getElementById('#{id}').click()")

  defp saved_at(session, account, entry, position) do
    %{session_id: player} = Library.entry(account, entry.id).playback

    {:ok, _} =
      Sikio.Playback.save(account, entry.id, player, %{
        "sequence" => 1,
        "position" => position,
        "duration" => 3723,
        "ended" => false
      })

    session
  end

  # Whether a script returns true, for `retry/1`: what is painted may lag a frame behind the DOM.
  defp holds(session, script) do
    execute_script(session, script, fn value -> Process.put(:holds, value) end)
    if Process.delete(:holds) == true, do: {:ok, session}, else: {:error, :not_yet}
  end

  defp below(lower, upper) do
    """
    return document.querySelector('#{lower}').getBoundingClientRect().top >=
           document.querySelector('#{upper}').getBoundingClientRect().bottom
    """
  end

  defp flush(a, b) do
    """
    const a = document.querySelector('#{a}').getBoundingClientRect(),
          b = document.querySelector('#{b}').getBoundingClientRect()
    return Math.abs(a.left - b.left) <= 1 && Math.abs(a.width - b.width) <= 1
    """
  end

  defp within(inner, outer) do
    """
    const a = document.querySelector('#{inner}').getBoundingClientRect(),
          b = document.querySelector('#{outer}').getBoundingClientRect()
    return a.left >= b.left && a.right <= b.right + 1 && a.top >= b.top - 1
    """
  end

  # A property, not an attribute. An attribute belongs to the markup, so an element rebuilt from
  # the same template would carry it again and prove nothing. A property lives on the DOM node and
  # cannot survive that node being replaced, which is the difference between the same-looking
  # element and the same element.
  defp mark_player(session),
    do: execute_script(session, "document.querySelector('#player-panel audio').sikioKept = true")

  defp assert_same_player(session) do
    execute_script(
      session,
      "return document.querySelector('#player-panel audio').sikioKept === true",
      fn kept -> assert kept, "the audio element was replaced" end
    )
  end

  # A network drop, from the server's side: the connection dies without a closing handshake, so the
  # browser sees an abnormal close and reconnects on its own. A close started in the browser comes
  # back as a normal one, which LiveView answers by reloading the page instead. The observer marks
  # the body once the dock has lost its connection and got it back, so the test waits for that.
  defp drop_socket(session, account) do
    execute_script(session, """
    const dock = document.querySelector('#player-dock > [data-phx-session]')
    let dropped = false
    new MutationObserver(() => {
      if (!dock.classList.contains('phx-connected')) dropped = true
      else if (dropped) document.body.dataset.rejoined = ''
    }).observe(dock, {attributes: true, attributeFilter: ['class']})
    """)

    Process.exit(dock_socket(account).transport_pid, :kill)
    session
  end

  defp dock_socket(account) do
    Enum.find_value(Process.list(), fn pid ->
      with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
           {PlayerDockLive, :mount, 3} <- dictionary[:"$initial_call"],
           %{socket: socket} <- :sys.get_state(pid),
           true <- socket.assigns.current_account.id == account.id do
        socket
      else
        _ -> nil
      end
    end)
  end

  defp settled(session) do
    result = execute_script(session, padding(), fn value -> Process.put(:padding, value) end)

    case Process.delete(:padding) do
      "0px" -> {:ok, result}
      other -> {:error, {:still_padded, other}}
    end
  end

  defp padding,
    do: "return getComputedStyle(document.querySelector('#page-content')).paddingBottom"
end
