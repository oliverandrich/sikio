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
    |> open("/")
    |> click(css("#play-#{entry.id}"))
    |> click(css("#start-playback"))
    # Pinned to the detail the panel leaves the title to it, so the player says what it plays.
    |> assert_has(css(~s|#player-control[data-entry-id="#{entry.id}"]|))
    |> assert_has(css("#player-panel audio"))
    |> mark_player()
    |> click(css("#subscriptions-heading"))
    |> assert_has(css("h1", text: "Make room"))
    # From lg the panel folds into the sidebar's bar there, which keeps the audio mounted but
    # out of sight. What this asks is that it is the same element.
    |> assert_has(css("#player-panel audio", visible: false))
    |> assert_same_player()

    assert Library.entry(account, entry.id).playback.session_id
  end

  feature "the compact button folds the panel without unmounting the audio", context do
    %{session: session, entry: entry} = context

    session
    |> open("/library/#{entry.id}")
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel audio"))
    |> mark_player()
    |> click(css("#compact-player"))
    |> assert_has(css("#compact-player[aria-pressed='true']"))
    |> assert_has(css("#player-panel audio"))
    |> execute_script(
      "return getComputedStyle(document.querySelector('#player-panel .player-speed')).display",
      fn display -> assert display == "none" end
    )
    |> assert_same_player()
  end

  feature "the player survives a dropped and restored socket", context do
    %{session: session, account: account, entry: entry} = context

    session
    |> open("/library/#{entry.id}")
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel audio"))
    |> mark_player()
    |> drop_socket(account)
    |> assert_has(css("body[data-rejoined]"))
    |> assert_has(css("#player-panel audio"))
    |> assert_same_player()

    assert Library.entry(account, entry.id).playback.session_id
  end

  # The room is for the floating panel, which only a narrow screen has.
  feature "closing the player gives the page its scroll room back", context do
    %{session: session, entry: entry} = context

    session
    |> resize_window(500, 900)
    |> open("/library/#{entry.id}")
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel"))
    |> execute_script(padding(), fn padding -> refute padding == "0px" end)
    |> click(css("#close-player"))

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

    feature "is the top of the detail that shows what plays", context do
      %{session: session, entry: entry} = context

      session
      |> resize_window(1280, 900)
      |> open("/library/#{entry.id}")
      |> click(css("#start-playback"))
      |> assert_has(css(~s|#player-panel[data-place="pinned"] audio|))
      |> execute_script(within("#player-panel", "#item-detail"), fn inside -> assert inside end)
      # The detail beneath names the source and the title already.
      |> assert_has(css("#player-panel .player-title", visible: false))
      |> assert_has(css("#player-panel .player-source", visible: false))
      # It sits on the detail's card, not on the column around it.
      |> execute_script(flush("#player-panel", "#item-detail article"), fn flush ->
        assert flush
      end)
    end

    # Playback is global and selection is not. When they disagree the notes get the room, and on a
    # page without a detail the bar still says what plays and can pause it.
    feature "folds into the sidebar when the detail shows something else", context do
      %{session: session, account: account, entry: entry, video: video} = context

      session
      |> resize_window(1280, 900)
      |> open("/library/#{entry.id}")
      |> click(css("#start-playback"))
      |> assert_has(css("#player-panel audio"))
      |> mark_player()
      |> click(css("#play-#{video.id}"))
      |> assert_has(css(~s|#player-panel[data-place="compact"] #dock-toggle|))
      |> execute_script(within("#player-panel", "header:has(#main-navigation)"), fn inside ->
        assert inside
      end)
      |> click(css("#subscriptions-heading"))
      |> assert_has(css(~s|#player-panel[data-place="compact"]|))
      |> assert_same_player()
      # Nothing is served to play here, so the audio's own play event is what the test sends.
      |> assert_has(css("#dock-toggle .dock-play"))
      |> execute_script(
        "document.querySelector('#player-panel audio').dispatchEvent(new Event('play'))"
      )
      |> assert_has(css("#dock-toggle .dock-pause"))
      |> assert_has(css("#dock-toggle .dock-play", visible: false))
      |> saved_at(account, entry, 30)
      # A saved place patches the bar. The button has to keep saying pause through it.
      |> assert_has(css("#player-panel .player-status", text: "0:30"))
      |> assert_has(css("#dock-toggle .dock-pause"))
    end
  end

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
