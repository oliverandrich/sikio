defmodule SikioWeb.PlayerTest do
  @moduledoc """
  The player in a real browser, which is the only place it exists.

  `Phoenix.LiveViewTest` can render the dock and answer its events, but it cannot say whether the
  audio element survives navigation, whether the panel stays outside the view that gets swapped, or
  what the page looks like once it is compacted. Those are the properties the dock exists for.

  The audio itself never loads here, because nothing serves it. That is deliberate: what is being
  checked is the element and the page around it, not somebody else's media server.
  """
  use SikioWeb.FeatureCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  setup %{session: session} do
    virtual_authenticator(session)

    session
    |> open("/")
    |> fill_in(css("input[name=username]"), with: "ada")
    |> click(button("Create your passkey"))
    |> landed_on("/recovery-codes")

    account = Repo.get_by!(User, username: "ada")
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, _subscription} = Library.subscribe(account, preview)
    [entry] = Library.entries(account)

    %{account: account, entry: entry}
  end

  feature "an episode keeps playing while the pages around it change", context do
    %{session: session, account: account, entry: entry} = context

    session
    |> open("/")
    |> click(css("#play-#{entry.id}"))
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel", text: entry.title))
    |> assert_has(css("#player-panel audio"))

    # The element that holds the media, identified before and after navigating. If the dock were
    # inside the navigated view, this would be a different element afterwards, and a different
    # element means the media started over.
    playing = player_element_id(session)

    session
    |> click(css("#subscriptions-link"))
    |> assert_has(css("h1", text: "Make room"))
    |> assert_has(css("#player-panel audio"))

    assert player_element_id(session) == playing
    assert Library.entry(account, entry.id).playback.session_id
  end

  feature "the compact button folds the panel without unmounting the audio", context do
    %{session: session, entry: entry} = context

    session
    |> open("/library/#{entry.id}")
    |> click(css("#start-playback"))
    |> assert_has(css("#player-panel audio"))

    playing = player_element_id(session)

    session
    |> click(css("#compact-player"))
    |> assert_has(css("#compact-player[aria-pressed='true']"))
    |> assert_has(css("#player-panel audio"))
    |> execute_script(
      "return getComputedStyle(document.querySelector('#player-panel .player-speed')).display",
      fn display -> assert display == "none" end
    )

    assert player_element_id(session) == playing
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

  defp settled(session) do
    result = execute_script(session, padding(), fn value -> Process.put(:padding, value) end)

    case Process.delete(:padding) do
      "0px" -> {:ok, result}
      other -> {:error, {:still_padded, other}}
    end
  end

  defp padding,
    do: "return getComputedStyle(document.querySelector('#page-content')).paddingBottom"

  defp player_element_id(session) do
    session
    |> find(css("#player-panel [phx-hook='MediaPlayer']"))
    |> Element.attr("id")
  end
end
