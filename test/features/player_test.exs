# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlayerTest do
  @moduledoc """
  Player features in Chrome.

  `Phoenix.LiveViewTest` can render the dock and handle its events.
  It cannot show whether the audio element survives navigation.
  Nor whether the panel stays outside the swapped LiveView, or how the compact layout renders.
  The dock exists for these properties.

  No server serves the audio, so it never loads.
  The tests check that the element is never replaced, not a media server.
  Audio output on a real speaker needs a real device and is tracked separately.
  """
  use SikioWeb.FeatureCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias SikioWeb.PlayerDockLive

  @notes "#item-notes, #item-no-notes"

  setup %{session: session} do
    account = signed_in(session, "ada")
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
    # Pinned to the detail, the panel shows no title of its own.
    # `data-entry-id` on `#player-control` identifies the playing entry.
    |> assert_has(css(~s|#player-control[data-entry-id="#{entry.id}"]|))
    |> assert_has(css("#player-panel [data-audio-face]"))
    |> mark_player()
    |> click(css("#add-button"))
    |> assert_has(css("h1", text: "Add a source"))
    # From lg the panel folds into the sidebar bar on this page, mounted but hidden.
    # The test checks that it is the same element.
    |> assert_has(css("#player-panel audio", visible: false))
    |> assert_same_player()

    assert Library.entry(account, entry.id).playback.session_id
  end

  # On a phone the playing panel lies over the card's own player.
  # Two players for one episode could disagree, so the card's player is hidden while it plays.
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

  # The Media Session metadata names the episode and its artwork.
  # The lock screen and media keys use it.
  # It is cleared when the player closes.
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

  # An ended item starts the next item in the queue when continuous play is enabled.
  # No audio is served, so the test dispatches the `ended` event.
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

  # When playback continues from the ended item's detail, the detail follows to the next item.
  # This requires the visible list to contain that item. The player is pinned in the new detail.
  # The URL stays in the queue list.
  feature "the detail follows the queue to the next item", context do
    follows_the_queue(context, {1280, 900})
  end

  # On a phone the detail covers the list, which still contains the next item.
  feature "on a phone the detail follows the queue to the next item", context do
    follows_the_queue(context, {500, 900})
  end

  defp follows_the_queue(%{session: session, account: account, entry: entry}, {width, height}) do
    following = queued_after(account, entry)

    session
    |> resize_window(width, height)
    |> open(SikioWeb.LibraryPaths.library_path(%{"status" => "queue"}, entry))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-control[data-entry-id="#{entry.id}"]|))
    |> execute_script(
      "document.querySelector('#player-panel audio').dispatchEvent(new Event('ended'))"
    )
    |> assert_has(css(~s|#player-control[data-entry-id="#{following.id}"]|))
    |> assert_has(css(~s|#item-detail[data-entry-id="#{following.id}"]|))
    |> assert_has(css(~s|#player-panel[data-place="pinned"]|))
    |> then(&assert(current_path(&1) =~ ~r|^/queue/#{following.id}-|))
  end

  # The last queued item ends and nothing follows. The queue is empty, so the detail is too.
  # Neither the detail nor the dock shows an item the list no longer contains.
  feature "the detail empties when the queue plays out its last item", context do
    %{session: session, account: account, entry: entry} = context
    {:ok, _} = Sikio.Playback.enqueue(account, entry.id, :last)

    session
    |> resize_window(1280, 900)
    |> open(SikioWeb.LibraryPaths.library_path(%{"status" => "queue"}, entry))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-control[data-entry-id="#{entry.id}"]|))
    # No audio is served, so the test dispatches `loadedmetadata` and `ended`.
    # Only a loaded player saves the end, which removes the item from the queue.
    |> execute_script("""
    const audio = document.querySelector('#player-panel audio')
    audio.dispatchEvent(new Event('loadedmetadata'))
    audio.dispatchEvent(new Event('ended'))
    """)
    |> gone(css("#item-detail h2"))
    |> gone(css("#player-panel"))
    |> then(&assert(current_path(&1) == "/queue"))
  end

  # Queues the entry, then an episode of another podcast.
  defp queued_after(account, entry) do
    {:ok, preview} = Parser.parse(podcast("Next up"), feed_url("next"))
    {:ok, subscription} = Library.subscribe(account, preview)
    [following] = Library.entries(account, %{"source" => to_string(subscription.feed_id)})
    {:ok, _} = Sikio.Playback.enqueue(account, entry.id, :last)
    {:ok, _} = Sikio.Playback.enqueue(account, following.id, :last)
    following
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

  # The bottom padding of `#page-content` is for the floating panel.
  # Only narrow screens have that panel.
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

    # Waiting for this value also waits for the close round trip.
    # Removing the panel resets the padding to zero.
    assert {:ok, _} = retry(fn -> settled(session) end)
    gone(session, css("#player-panel"))
  end

  # From lg a pinned video's height is 9/16 of its width, capped at the window height.
  # The panel has no overflow.
  feature "from lg a video grows to the window's height and the panel never scrolls", context do
    %{session: session, account: account} = context
    video = video_with_notes(account)

    session
    |> resize_window(1920, 500)
    |> open(item_path(video))
    |> click(css("#start-playback"))
    |> assert_has(css(~s|#player-panel[data-place="pinned"] iframe|))
    |> execute_script(
      """
      const panel = document.getElementById('player-panel')
      const frame = panel.querySelector('iframe').getBoundingClientRect()
      return [panel.scrollHeight - panel.clientHeight, frame.height,
              Math.min(frame.width * 9 / 16, innerHeight)]
      """,
      fn [overflow, height, expected] ->
        assert overflow == 0, "the panel scrolls by #{overflow}px"
        assert_in_delta height, expected, 1
      end
    )
  end

  describe "from lg, the player's place" do
    setup %{account: account} do
      {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
      {:ok, _} = Library.subscribe(account, preview)
      [video] = Enum.filter(Library.entries(account), &(&1.feed.kind == :youtube))
      %{video: video}
    end

    # The card menu renders above the pinned player, not beneath it.
    feature "the card's menu opens over the playing player", context do
      %{session: session, entry: entry} = context

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> click(css("#start-playback"))
      |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
      |> click(css("#item-more summary"))
      |> assert_has(css("#item-more[open] #dequeue", visible: true))
      |> execute_script(
        """
        const box = document.getElementById('dequeue').getBoundingClientRect()
        const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)
        return hit.closest('#item-more') !== null
        """,
        fn on_top -> assert on_top, "the menu lies under the player" end
      )
    end

    # The player sits at the head of the detail card, above the title and notes.
    # A video spans its card edge to edge, as on a phone.
    # The video position is measured before playback, so nothing is requested from YouTube.
    feature "is in the detail that shows what plays, above its title", context do
      %{session: session, account: account, entry: entry, video: video} = context

      session
      |> resize_window(1280, 900)
      |> open(item_path(video))
      |> assert_has(css("#player-slot #start-playback"))
      |> execute_script(flush("#player-slot", "#item-detail article"), fn flush ->
        assert flush
      end)
      |> open(item_path(entry))
      |> click(css("#start-playback"))
      |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
      |> execute_script(within("#player-panel", "#item-detail"), fn inside -> assert inside end)
      # The detail shows the source and title, and selecting another item closes the player.
      # So the pinned panel hides its heading and its close button.
      |> assert_has(css("#player-panel .player-heading", visible: false))
      |> assert_has(css("#close-player", visible: false))
      # It is flush with the detail card, not the surrounding column.
      |> execute_script(flush("#player-panel", "#player-slot"), fn flush -> assert flush end)
      # The player comes first. The title starts the text column, aligned with the notes.
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
      # Saving a position patches the detail and the dock.
      # Neither patch may remove the placement attributes.
      # Removal for even one frame causes a flicker.
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
        # The dock's status is hidden while pinned, and WebDriver reads only visible text.
        status = "#player-panel .player-status"
        script = "return document.querySelector('#{status}').textContent.includes('0:30')"
        assert {:ok, _} = retry(fn -> holds(session, script) end)
        session
      end)
      |> execute_script("return window.sikioLost", fn lost -> assert lost == [] end)
      # The slot follows the player's height, so the notes stay below it.
      # The test sets the face height to 300px.
      |> execute_script(
        "document.querySelector('#player-panel [data-audio-face]').style.height = '300px'"
      )
      |> then(fn session ->
        assert {:ok, _} = retry(fn -> holds(session, below(@notes, "#player-panel")) end)
        session
      end)
    end

    # Before loading, the card shows its own player.
    # Releasing its seek bar starts the dock player in the same box.
    feature "the card's player starts where it is dragged to and is covered without a jump",
            context do
      %{session: session, account: account, entry: entry} = context

      box =
        "const b = document.querySelector(arguments[0]).getBoundingClientRect(); return [b.left, b.top, b.width, b.height].map(Math.round)"

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> gone(css("#player-panel"))
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
        # Compares the panel's face, not the panel.
        # The message line below the face is empty and collapsed.
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

    # A chapter starts the item at its time. During playback another chapter seeks the player.
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
      # The audio never loads here. A seek on an element without media depends on load timing.
      # The node tests cover that the player seeks the audio.
      # This test checks that the click reaches the playing player with the chapter's time.
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

    # Sikio's controls act on the audio element. The seek bar applies its value on release.
    # The skip buttons jump, and the speed button steps up.
    # The audio never loads, so the test checks the element's properties.
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

    # Focus stays on the page, and page keys control the player.
    # p starts the open item like its play button, then toggles play and pause. Arrows skip.
    # Space sends no player command. Library keys such as m keep working.
    feature "the page's keys drive the player", context do
      %{session: session, account: account, entry: entry} = context

      session
      |> resize_window(1280, 900)
      |> open(item_path(entry))
      |> assert_has(css("#start-playback"))
      |> gone(css("#player-control[data-entry-id]"))
      |> send_keys(["p"])
      |> assert_has(css(~s|#player-panel[data-place="pinned"] [data-audio-face]|))
      |> assert_has(css(~s|#player-control[data-entry-id="#{entry.id}"]|))
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
      |> assert_has(css("#mark-new", visible: false))

      assert Library.entry(account, entry.id).playback.status == :heard
    end

    # A click into a video iframe moves keyboard focus into the frame, out of the page's handlers.
    # The page then focuses the panel. A `srcdoc` iframe stands in for the video.
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
      # Waits three frames first, so no pending placement runs after the scroll.
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
      # Measures two frames after the scroll, with no other change in between.
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

    # The compact player's title opens the playing item in the current list, if it contains it.
    # Regression: the title linked to a URL without a list, which switched to all items.
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

      # Uses all items, because playing moves an item from the inbox to the queue.
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

    # Starting items in sequence hands the player on each time, and the last one still closes.
    # Each start waits for the previous player to save its position.
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

      # Navigates by clicks in the list, so the page and its player are not reloaded.
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
      |> gone(css("#player-panel"))
    end

    # Playback is global, selection is not. When they differ, the notes get the detail space.
    # The player floats at the bottom left at twice the sidebar width.
    # It covers the bottom of the sidebar and the list. The list has padding to scroll past it.
    # On a page without a detail the player stays, and its play button follows the audio state.
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
      |> click(css("#add-button"))
      |> assert_has(css(~s|#player-panel[data-place="compact"]|))
      |> assert_same_player()
      # No audio is served, so the test dispatches the `play` event.
      |> assert_has(css("#player-panel [data-audio-play] .audio-icon-play"))
      |> execute_script(
        "document.querySelector('#player-panel audio').dispatchEvent(new Event('play'))"
      )
      |> assert_has(css("#player-panel [data-audio-play] .audio-icon-pause"))
      |> assert_has(css("#player-panel [data-audio-play] .audio-icon-play", visible: false))
      |> saved_at(account, entry, 30)
      # Saving a position patches the panel. The button must keep showing pause.
      |> then(fn session ->
        script =
          "return document.querySelector('#player-panel .player-status').textContent.includes('0:30')"

        assert {:ok, _} = retry(fn -> holds(session, script) end)
        session
      end)
      |> assert_has(css("#player-panel [data-audio-play] .audio-icon-pause"))
    end
  end

  # Clicks a floating-panel button by script, not at screen coordinates.
  # The panel sits on the bottom bar and grows upward when its message line fills.
  # The unserved audio fills it here, so a coordinate click can hit the seek bar instead.
  # These tests check the button's effect, not its position.
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

  # For `retry/1`: succeeds when the script returns true. Rendering may lag the DOM by a frame.
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

  # Sets a property, not an attribute.
  # An element rebuilt from the same template carries the attribute again.
  # A property exists only on the DOM node and is lost when the node is replaced.
  # So it distinguishes the same element from an identical-looking one.
  defp mark_player(session),
    do: execute_script(session, "document.querySelector('#player-panel audio').sikioKept = true")

  defp assert_same_player(session) do
    execute_script(
      session,
      "return document.querySelector('#player-panel audio').sikioKept === true",
      fn kept -> assert kept, "the audio element was replaced" end
    )
  end

  # Simulates a server-side network drop. Killing the transport skips the close handshake.
  # The browser sees an abnormal close and reconnects by itself.
  # A close initiated in the browser is normal, and LiveView reloads the page instead.
  # The MutationObserver sets `data-rejoined` after the dock disconnects and reconnects.
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
