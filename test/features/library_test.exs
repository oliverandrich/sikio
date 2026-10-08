# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryTest do
  @moduledoc """
  The library list and detail in Chrome, including loading more rows on scroll.

  `Phoenix.LiveViewTest` can send the viewport event.
  It cannot show whether the browser sends it when the list end enters the viewport.
  """
  use SikioWeb.FeatureCase

  import Ecto.Query

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  # Waits for two animation frames, after which a patch or a scroll has been laid out.
  @frames "const frame = () => new Promise(resolve => requestAnimationFrame(resolve))"

  setup %{session: session} do
    account = signed_in(session, "ada")
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")

    entries =
      for n <- 1..40,
          do: %{hd(preview.entries) | external_id: "episode-#{n}", title: "Episode #{n}"}

    {:ok, _} = Library.subscribe(account, %{preview | entries: entries})
    %{account: account}
  end

  # Queue rows move by their handles: by pointer drag, or one position per arrow key.
  feature "the queue is put in order by dragging and by keys", %{
    session: session,
    account: account
  } do
    ids =
      for title <- ["Episode 1", "Episode 2", "Episode 3"] do
        id = Sikio.Repo.one!(from e in Sikio.Feeds.Entry, where: e.title == ^title, select: e.id)
        {:ok, _} = Sikio.Playback.enqueue(account, id, :last)
        id
      end

    [one, two, three] = ids

    order =
      "return [...document.querySelectorAll('#entries article')].map(row => row.querySelector('[data-move]').dataset.move)"

    session
    |> resize_window(1280, 900)
    |> open("/queue")
    |> assert_has(css("#entries article", count: 3))
    # Drags Episode 3 above the first row.
    |> execute_script("""
    const handle = document.getElementById('move-#{three}')
    const top = document.getElementById('move-#{one}').getBoundingClientRect().top
    const at = (type, y) => handle.dispatchEvent(new PointerEvent(type, {bubbles: true, clientY: y, pointerId: 1, button: 0}))
    const start = handle.getBoundingClientRect().top + 10
    window.sikioTop = top + 5
    at('pointerdown', start); at('pointermove', top + 5)
    """)
    # While the pointer is held, the first row already has a transform to make room.
    |> execute_script(
      "return getComputedStyle(document.getElementById('move-#{one}').closest('article')).transform",
      fn transform -> assert transform =~ "matrix", "the first row stays put while held over" end
    )
    |> execute_script("""
    const handle = document.getElementById('move-#{three}')
    handle.dispatchEvent(new PointerEvent('pointerup', {bubbles: true, clientY: window.sikioTop, pointerId: 1, button: 0}))
    """)
    |> then(fn session ->
      wanted = Enum.map([three, one, two], &to_string/1)
      assert {:ok, _} = retry(fn -> in_order(session, order, wanted) end)
      session
    end)
    # Moves Episode 3 down one position with the arrow key on its handle.
    |> execute_script("document.getElementById('move-#{three}').focus()")
    |> send_keys([:down_arrow])
    |> then(fn session ->
      wanted = Enum.map([one, three, two], &to_string/1)
      assert {:ok, _} = retry(fn -> in_order(session, order, wanted) end)
      session
    end)
  end

  defp in_order(session, script, wanted) do
    execute_script(session, script, fn got -> Process.put(:order, got) end)
    if Process.delete(:order) == wanted, do: {:ok, session}, else: {:error, :not_yet}
  end

  # ? opens the shortcut overview and Escape closes it. The account menu also opens it.
  # f opens the search, focused and empty. The magnifier button also opens it.
  # Escape clears and closes the search and moves focus to the magnifier.
  feature "? shows every key, and f or the magnifier opens the search", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#entries article", count: 25))
    |> gone(css("#shortcuts[open]"))
    # chromedriver sends ? as Shift plus underscore. A keyboard sends the character in any layout.
    # The page reads that character, so the test dispatches the event directly.
    |> execute_script(
      "document.body.dispatchEvent(new KeyboardEvent('keydown', {key: '?', shiftKey: true, bubbles: true}))"
    )
    |> assert_has(css("#shortcuts[open]", text: "Play or pause"))
    |> assert_has(css("#shortcuts", text: "Previous or next chapter"))
    |> assert_has(css("#entries article:nth-of-type(1) a[aria-current]"))
    # Keys typed into the open overview do not reach the page.
    # A `j` dispatched on the body moves the selection by one, and the overview stays open.
    |> send_keys(["j"])
    |> execute_script(
      "document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'j', bubbles: true}))"
    )
    |> assert_has(css("#entries article:nth-of-type(2) a[aria-current]"))
    |> assert_has(css("#shortcuts[open]"))
    |> send_keys([:escape])
    |> gone(css("#shortcuts[open]"))
    |> gone(css("#search-input"))
    |> send_keys(["f"])
    |> assert_has(css("#search-input"))
    |> execute_script("return [document.activeElement.id, document.activeElement.value]", fn
      [id, value] ->
        assert id == "search-input"
        assert value == ""
    end)
    |> fill_in(css("#search-input"), with: "Episode 17")
    |> assert_has(css("#entries article", count: 1))
    |> send_keys([:escape])
    |> assert_has(css("#entries article", count: 25))
    |> gone(css("#search-input"))
    |> execute_script("return document.activeElement.id", fn id ->
      assert id == "toggle-search"
    end)
    |> click(css("#toggle-search"))
    |> assert_has(css("#search-input"))
    |> execute_script("return document.activeElement.id", fn id -> assert id == "search-input" end)
    |> click(css("#user-menu summary"))
    |> click(css("#show-shortcuts"))
    |> assert_has(css("#shortcuts[open]"))
  end

  # The mark-all dialog takes focus when it opens, and Escape closes it.
  # It offers to keep the player's item only while the player has one.
  # Unticking that option lowers the count by one and leaves the item unarchived.
  # The others are archived: still listed under all items, not counted under heard.
  feature "the double check marks a list after asking, and may leave the item in the player", %{
    session: session
  } do
    # Uses all items, because the playing item moves to the queue and leaves the inbox.
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> click(css("#mark-all"))
    |> assert_has(css("dialog#mark-all-confirm[open]", text: "40 items in this list"))
    # The dialog element takes focus, so no button shows a focus ring before tabbing.
    |> execute_script("return document.activeElement.id", fn id ->
      assert id == "mark-all-confirm"
    end)
    |> gone(css("#mark-all-playing"))
    |> send_keys([:escape])
    |> gone(css("#mark-all-confirm"))
    |> click(css("#start-playback"))
    |> assert_has(css("#player-control[data-entry-id]"))
    |> click(css("#mark-all"))
    |> assert_has(css("#mark-all-playing input[name=playing][type=checkbox]:checked"))
    |> click(css("#mark-all-playing input[name=playing][type=checkbox]"))
    |> assert_has(css("dialog#mark-all-confirm[open]", text: "39 items in this list"))
    |> click(css("#confirm-mark-all"))
    |> assert_has(css("#view-queue-count", text: "1"))
    |> assert_has(css("#entries article:not([data-status=archived])", count: 1))
    |> assert_has(css("#library-count", text: "40 items"))
    |> gone(css("#view-heard-count"))
  end

  # Escape closes a subscription's dialog and returns focus to the element that opened it.
  feature "the subscriptions page gives the focus back after its dialog", %{
    session: session,
    account: account
  } do
    [subscription] = Library.subscriptions(account)

    session
    |> resize_window(1440, 900)
    |> open("/subscriptions")
    |> click(css("#edit-subscription-#{subscription.id}"))
    |> assert_has(css("dialog#edit-subscription-confirm[open]"))
    |> send_keys([:escape])
    |> gone(css("#edit-subscription-confirm"))
    |> execute_script("return document.activeElement.id", fn id ->
      assert id == "edit-subscription-#{subscription.id}"
    end)
  end

  # A click on an external link without `target` sets `target="_blank"`.
  # So an installed app never loads a foreign page in its own window.
  feature "a link away without a target gets target=_blank on click", %{session: session} do
    session
    |> open("/inbox")
    |> execute_script("""
    const link = document.createElement('a')
    link.id = 'away'
    link.href = 'https://example.org/elsewhere'
    link.textContent = 'away'
    document.body.append(link)
    link.addEventListener('click', event => { window.awayTarget = link.target; event.preventDefault() })
    """)
    |> click(css("#away"))
    |> execute_script("return window.awayTarget", fn target -> assert target == "_blank" end)
  end

  # A source gets a tag in its own dialog, which stays open while typing.
  # The tag then appears in the sidebar as its own list.
  # Unsubscribing uses the same dialog, after a confirmation that names the source.
  feature "a source is tagged and left from its own list", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/inbox")
    |> gone(css("#tags-heading"))
    |> click(css("#sidebar a", text: "Small Hours"))
    |> click(css("#edit-subscription"))
    |> assert_has(css("dialog#edit-subscription-confirm[open]", text: "Small Hours"))
    |> fill_in(css("#subscription-form input[name=new]"), with: "Must view")
    |> assert_has(css("dialog#edit-subscription-confirm[open]"))
    |> click(css("#confirm-edit-subscription"))
    |> gone(css("#edit-subscription-confirm"))
    |> click(css("#sidebar a", text: "Must view"))
    |> assert_has(css("#library-heading", text: "Must view"))
    |> assert_has(css("#entries article", count: 25))
    |> click(css("#sidebar a", text: "Small Hours"))
    |> click(css("#edit-subscription"))
    |> click(css("#unsubscribe"))
    |> assert_has(css("dialog#unsubscribe-confirm[open]", text: "Unsubscribe from Small Hours?"))
    |> send_keys([:escape])
    |> gone(css("#unsubscribe-confirm"))
    |> click(css("#edit-subscription"))
    |> click(css("#unsubscribe"))
    |> click(css("#confirm-unsubscribe"))
    |> gone(css("#sidebar a", text: "Small Hours"))
    |> assert_has(css("#library-heading", text: "Queue"))
  end

  # From lg the window does not scroll. The list and the detail scroll in separate columns.
  # Scrolling the list leaves the detail in place.
  # Both columns have `tabIndex` 0 for keyboard scrolling.
  # Chrome focuses scroll containers without it, Safari does not.
  # Selecting another item resets the detail to its top.
  feature "the list and the detail scroll on their own", %{session: session} do
    session
    |> resize_window(1440, 400)
    |> open("/all")
    |> assert_has(css("#item-detail h2", text: "Episode 40"))
    |> execute_script(
      "return ['list-pane', 'item-detail'].map(id => document.getElementById(id).tabIndex)",
      fn indexes -> assert indexes == [0, 0] end
    )
    |> execute_script("""
    window.sikioDetailTop = document.querySelector('#item-detail article').getBoundingClientRect().top
    document.getElementById('list-pane').scrollTop = 1200
    """)
    |> execute_script(
      """
      const top = id => Math.round(document.getElementById(id).getBoundingClientRect().top)
      return [document.getElementById('list-pane').scrollTop, window.scrollY, top('list-head'),
              Math.round(document.querySelector('#item-detail article').getBoundingClientRect().top - window.sikioDetailTop),
              document.documentElement.scrollHeight - window.innerHeight]
      """,
      fn [list, window, head, detail_moved, page_room] ->
        assert list > 0
        assert window == 0
        assert head == 0
        assert detail_moved == 0, "the detail does not move with the list"
        assert page_room <= 0, "the page itself has nothing to scroll"
      end
    )
    # Resets the list scroll, so the clicked row is not under the list head.
    # The detail stays scrolled, so the reset for the next item is observable.
    |> execute_script(
      """
      document.getElementById('list-pane').scrollTop = 0
      const detail = document.getElementById('item-detail')
      detail.scrollTop = 150
      return detail.scrollTop
      """,
      fn top -> assert top > 0 end
    )
    |> click(css("#entries article:nth-of-type(2) a"))
    |> assert_has(css("#item-detail h2", text: "Episode 39"))
    |> execute_script("return document.getElementById('item-detail').scrollTop", fn top ->
      assert top == 0
    end)
    # Runs last, because keyboard scrolling is smooth and keeps moving the column afterwards.
    |> execute_script("document.getElementById('item-detail').focus()")
    |> send_keys([" "])
    |> execute_script(
      # Keys scroll smoothly, so the script waits up to a second for the column to move.
      """
      const detail = document.getElementById('item-detail'), until = performance.now() + 1000
      return new Promise(function wait(resolve) {
        if (detail.scrollTop > 0 || performance.now() > until) resolve(detail.scrollTop)
        else requestAnimationFrame(() => wait(resolve))
      })
      """,
      fn top -> assert top > 0 end
    )
    |> execute_script(
      "return [window.scrollY, Math.round(document.getElementById('list-head').getBoundingClientRect().top)]",
      fn [window, head] ->
        assert window == 0
        assert head == 0
      end
    )
  end

  # The selected row stays visible below the list head.
  # Checked after moving with j and after opening a row's URL far down the list.
  feature "the chosen row stays in view", %{session: session} do
    session
    |> resize_window(1440, 500)
    |> open("/all")
    |> assert_has(css("#item-detail h2", text: "Episode 40"))
    |> send_keys(List.duplicate("j", 6))
    |> assert_has(css("#item-detail h2", text: "Episode 34"))
    |> execute_script(in_view("#entries article:nth-of-type(7)"), fn [below_head, above_end] ->
      assert below_head >= 0, "the row is not under the list's head"
      assert above_end >= 0, "the row is not cut off at the window's end"
    end)
    |> then(fn session ->
      href = session |> find(css("#entries article:nth-of-type(20) a")) |> Element.attr("href")
      open(session, href)
    end)
    |> assert_has(css("#item-detail h2", text: "Episode 21"))
    |> execute_script(
      # The list scrolls to the row after layout, one or two frames after the page loads.
      """
      #{@frames}
      return frame().then(frame).then(() => { #{in_view("#entries article:nth-of-type(20)")} })
      """,
      fn [below_head, above_end] ->
        assert below_head >= 0, "the opened row is not under the list's head"
        assert above_end >= 0, "the opened row is not cut off at the window's end"
      end
    )
  end

  # LiveView keeps the list's first child in view when the batch above loads.
  @first_row "return document.getElementById('entries').firstElementChild.id"

  defp episode(account, title),
    do: account |> Library.entries(%{}, limit: 50) |> Enum.find(&(&1.title == title))

  defp in_view(selector) do
    """
    const row = document.querySelector('#{selector}').getBoundingClientRect()
    const head = document.getElementById('list-head').getBoundingClientRect()
    return [Math.round(row.top - head.bottom), Math.round(window.innerHeight - row.bottom)]
    """
  end

  # A wide screen has room for the detail beside the list, so it shows the first item.
  # A phone shows only the list, because a selected item would cover it.
  feature "a wide screen shows the first item, a phone the list", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#item-detail h2", text: "Episode 40"))
    |> resize_window(500, 900)
    |> open("/all")
    # An absence check before the socket connects proves nothing.
    # The hook pushes its event only after connecting.
    # Events are handled in order, so once the search opens, the hook's mount event is handled.
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> assert_has(css("#entries article", count: 25))
    |> send_keys(["f"])
    |> assert_has(css("#search-input"))
    |> gone(css("#item-detail h2"))
  end

  feature "the list loads the next batch when its end comes into view", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#entries article", count: 25))
    |> execute_script("document.querySelector('#entries article:last-child').scrollIntoView()")
    |> assert_has(css("#entries article", count: 40))
  end

  # An item opened deep in the list loads with a window around it. Scrolling to the window's
  # top loads the batch above, and the row that was first stays where the reader sees it.
  feature "the list loads the batch above when its top comes into view", context do
    # At this height the fourteen rows above push the first row out of view.
    context.session
    |> resize_window(1440, 500)
    |> open(item_path(episode(context.account, "Episode 1")))
    |> assert_has(css("#item-detail h2", text: "Episode 1"))
    |> assert_has(css("#entries article", count: 26))
    |> execute_script(@first_row, fn first -> Process.put(:first, first) end)
    |> execute_script("document.getElementById('list-pane').scrollTop = 0")
    |> assert_has(css("#entries article", count: 40))
    |> execute_script("return document.getElementById('list-pane').scrollTop", fn scrolled ->
      assert scrolled > 0, "the list jumped to its new top"
    end)
    |> execute_script(
      "#{@frames}\nreturn frame().then(frame).then(() => { #{in_view("#" <> Process.get(:first))} })",
      fn [below_head, above_end] ->
        assert below_head >= -1, "the row that was first is hidden under the list's head"
        assert above_end >= 0, "the row that was first is cut off at the window's end"
      end
    )
  end

  # On a phone the page scrolls instead of the list pane, and the back link keeps the window.
  feature "a phone's list loads the batch above when its top comes into view", context do
    context.session
    |> resize_window(390, 844)
    |> open(item_path(episode(context.account, "Episode 1")))
    |> assert_has(css("#item-detail h2", text: "Episode 1"))
    |> click(css("#nav-back"))
    |> assert_has(css("#entries article", count: 26))
    |> execute_script(@first_row, fn first -> Process.put(:first, first) end)
    # A scroll event fires only on a change, so the page leaves its top before it returns.
    # Both scrolls in one frame would cancel out, so the second waits for two frames.
    |> execute_script("""
    #{@frames}
    window.scrollTo(0, document.body.scrollHeight)
    return frame().then(frame).then(() => window.scrollTo(0, 0))
    """)
    |> assert_has(css("#entries article", count: 40))
    |> execute_script(
      """
      #{@frames}
      return frame().then(frame).then(() => {
        const row = document.getElementById('#{Process.get(:first)}').getBoundingClientRect()
        return [window.scrollY, Math.round(row.top), Math.round(window.innerHeight - row.top)]
      })
      """,
      fn [scrolled, top, above_end] ->
        assert scrolled > 0, "the page jumped to the list's new top"
        assert top >= 0, "the row that was first is above the window"
        assert above_end > 0, "the row that was first is below the window"
      end
    )
  end
end
