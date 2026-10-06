# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.CardActionsTest do
  @moduledoc """
  The detail card's actions, whose names fit or not depending on the card's width.

  The card's width follows the columns beside it, not the window, so only a browser can say
  whether the names fit.
  """
  use SikioWeb.FeatureCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback

  # Started, a video stands in the queue, so its head offers marking it as watched.
  setup %{session: session} do
    account = signed_in(session, "ada")
    {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(account, preview)
    [video | _] = Library.entries(account)
    {:ok, _} = Playback.start(account, video.id)
    %{video: video}
  end

  # A narrow card shows its actions as icons, a wide one names them, and neither lets them run past
  # its edge.
  feature "a card names its actions where they fit and shows icons where not", context do
    %{session: session, video: video} = context

    session
    |> resize_window(1024, 800)
    |> open(item_path(video))
    |> assert_has(css("#item-actions > #mark-completed"))
    |> execute_script(measure(), fn [card_right, actions_right, label] ->
      assert actions_right <= card_right, "the actions stay inside the narrow card"
      assert label == "absolute", "the names are for screen readers only"
    end)
    |> resize_window(1920, 900)
    |> assert_has(css("#item-actions > #mark-completed", text: "Mark as watched"))
    |> execute_script(measure(), fn [card_right, actions_right, label] ->
      assert actions_right <= card_right, "the actions stay inside the wide card"
      assert label == "static"
    end)
  end

  # The rest waits in a menu, which opens, acts and closes again.
  feature "the menu at the card's head acts and closes", context do
    %{session: session, video: video} = context

    session
    |> resize_window(1440, 900)
    |> open(item_path(video))
    |> gone(css("#item-more #dequeue", visible: true))
    |> click(css("#item-more summary"))
    |> assert_has(css("#item-more[open] #dequeue", visible: true))
    |> click(css("#dequeue"))
    |> assert_has(css("#item-actions > #queue-menu"))
    |> gone(css("#item-more[open]"))
  end

  defp measure do
    """
    const card = document.querySelector('#item-detail article').getBoundingClientRect()
    const actions = document.getElementById('item-actions').getBoundingClientRect()
    const label = document.querySelector('#item-actions > #mark-completed span')
    return [Math.round(card.right), Math.round(actions.right), getComputedStyle(label).position]
    """
  end
end
