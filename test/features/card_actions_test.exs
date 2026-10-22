# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.CardActionsTest do
  @moduledoc """
  The detail card's actions, labelled or icon-only depending on the card width.

  The card width depends on the adjacent columns, not the window.
  So only a browser can measure it.
  """
  use SikioWeb.PlaywrightCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Playback

  # Starting playback queues the video, so the card head offers "Mark as watched".
  setup %{conn: conn} do
    account = signed_in(conn, "ada")
    {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(account, preview)
    [video | _] = Library.entries(account)
    {:ok, _} = Playback.start(account, video.id)
    %{video: video}
  end

  # A narrow card shows icons with visually hidden labels. A wide card shows the labels.
  # At both widths the actions end inside the card.
  test "a card names its actions where they fit and shows icons where not", context do
    %{conn: conn, video: video} = context

    conn
    |> resize(1024, 800)
    |> open(item_path(video))
    |> assert_has("#item-actions > #mark-completed")
    |> script(measure(), fn [card_right, actions_right, label] ->
      assert actions_right <= card_right, "the actions stay inside the narrow card"
      assert label == "absolute", "the names are for screen readers only"
    end)
    |> resize(1920, 900)
    |> assert_has("#item-actions > #mark-completed", text: "Mark as watched")
    |> script(measure(), fn [card_right, actions_right, label] ->
      assert actions_right <= card_right, "the actions stay inside the wide card"
      assert label == "static"
    end)
  end

  # A narrow card puts the actions in a row below the source and meta line, which keep its width.
  # Beside the list at 1280 px the card is wide enough for one row.
  test "a narrow card puts its actions in a row of their own", context do
    %{conn: conn, video: video} = context

    conn
    |> resize(390, 844)
    |> open(item_path(video))
    |> assert_has("#item-actions > #mark-completed")
    |> script(head(), fn head ->
      assert head["actionsTop"] >= head["metaBottom"], "the actions sit below the meta line"
      assert head["metaLines"] == 1, "the meta line does not wrap"
      assert head["actionsWidth"] >= head["cardWidth"] - 16, "the actions span the card"
    end)
    |> resize(1280, 800)
    |> script(head(), fn head ->
      assert head["actionsTop"] < head["metaBottom"], "the actions sit beside the meta line"
    end)
  end

  # The other actions are in the `#item-more` menu. It opens, runs an action and closes.
  test "the menu at the card's head acts and closes", context do
    %{conn: conn, video: video} = context

    conn
    |> resize(1440, 900)
    |> open(item_path(video))
    |> refute_has("#item-more #dequeue")
    |> click("#item-more summary")
    |> assert_has("#item-more[open] #dequeue")
    |> click("#dequeue")
    |> assert_has("#item-actions > #queue")
    |> refute_has("#item-more[open]")
  end

  defp head do
    """
    const card = document.querySelector('#item-detail article').getBoundingClientRect()
    const actions = document.getElementById('item-actions').getBoundingClientRect()
    const meta = document.getElementById('playback-status')
    const tops = new Set([...meta.children].filter(c => c.offsetParent).map(c => Math.round(c.getBoundingClientRect().top)))
    return {actionsTop: Math.round(actions.top), metaBottom: Math.round(meta.getBoundingClientRect().bottom),
            metaLines: tops.size, actionsWidth: Math.round(actions.width), cardWidth: Math.round(card.width)}
    """
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
