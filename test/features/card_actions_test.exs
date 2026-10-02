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

  # Started, a video offers all three: mark as watched, as new, and open on YouTube.
  setup %{session: session} do
    account = signed_up(session, "ada")
    {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(account, preview)
    [video | _] = Library.entries(account)
    {:ok, _} = Playback.start(account, video.id)
    %{video: video}
  end

  feature "a narrow card shows its actions as icons", context do
    %{session: session, video: video} = context

    session
    |> resize_window(1024, 800)
    |> open("/library/#{video.id}")
    |> assert_has(css("#item-actions #open-original"))
    |> execute_script(measure(), fn [card_right, actions_right, label] ->
      assert actions_right <= card_right, "the actions stay inside the card"
      assert label == "absolute", "the names are for screen readers only"
    end)
  end

  feature "a wide card names its actions", context do
    %{session: session, video: video} = context

    session
    |> resize_window(1920, 900)
    |> open("/library/#{video.id}")
    |> assert_has(css("#item-actions #open-original", text: "Open on YouTube"))
    |> execute_script(measure(), fn [card_right, actions_right, label] ->
      assert actions_right <= card_right
      assert label == "static"
    end)
  end

  defp measure do
    """
    const card = document.querySelector('#item-detail article').getBoundingClientRect()
    const actions = document.getElementById('item-actions').getBoundingClientRect()
    const label = document.querySelector('#open-original span')
    return [Math.round(card.right), Math.round(actions.right), getComputedStyle(label).position]
    """
  end
end
