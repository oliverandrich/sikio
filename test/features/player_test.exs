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
    virtual_authenticator(session)

    session
    |> open("/")
    |> code_entered()
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Create your passkey"))
    |> landed_on("/recovery-codes")

    account = Repo.get_by!(User, username: "ada")
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
    |> assert_has(css("#player-panel", text: entry.title))
    |> assert_has(css("#player-panel audio"))
    |> mark_player()
    |> click(css("#subscriptions-link"))
    |> assert_has(css("h1", text: "Make room"))
    |> assert_has(css("#player-panel audio"))
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

  feature "closing the player gives the page its scroll room back", context do
    %{session: session, entry: entry} = context

    session
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
