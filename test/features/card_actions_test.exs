# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.CardActionsTest do
  @moduledoc """
  The detail card's actions, labelled or icon-only depending on the card width.

  The card width depends on the adjacent columns, not the window.
  So only a browser can measure it.
  """
  use SikioWeb.FeatureCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback

  # Starting playback queues the video, so the card head offers "Mark as watched".
  setup %{session: session} do
    account = signed_in(session, "ada")
    {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(account, preview)
    [video | _] = Library.entries(account)
    {:ok, _} = Playback.start(account, video.id)
    %{video: video}
  end

  # A narrow card shows icons with visually hidden labels. A wide card shows the labels.
  # At both widths the actions end inside the card.
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

  # The other actions are in the `#item-more` menu. It opens, runs an action and closes.
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
