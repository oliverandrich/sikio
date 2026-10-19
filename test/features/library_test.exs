# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryTest do
  @moduledoc """
  The library list and detail in Chrome, including loading more rows on scroll.

  `Phoenix.LiveViewTest` can send the viewport event.
  It cannot show whether the browser sends it when the list end enters the viewport.
  """
  use SikioWeb.PlaywrightCase

  import Ecto.Query

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  # Waits for two animation frames, after which a patch or a scroll has been laid out.
  @frames "const frame = () => new Promise(resolve => requestAnimationFrame(resolve))"

  setup %{conn: conn} do
    account = signed_in(conn, "ada")
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")

    entries =
      for n <- 1..40,
          do: %{hd(preview.entries) | external_id: "episode-#{n}", title: "Episode #{n}"}

    {:ok, _} = Library.subscribe(account, %{preview | entries: entries})
    # Subscribing archives all but the newest. These features start with all 40 in the inbox.
    Repo.delete_all(Sikio.Playback.State)
    %{account: account}
  end

  # Queue rows move by their handles: by pointer drag, or one position per arrow key.
  test "the queue is put in order by dragging and by keys", %{
    conn: conn,
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

    conn
    |> resize(1280, 900)
    |> open("/queue")
    |> assert_has("#entries article", count: 3)
    # Drags Episode 3 above the first row.
    |> script("""
    const handle = document.getElementById('move-#{three}')
    const top = document.getElementById('move-#{one}').getBoundingClientRect().top
    const at = (type, y) => handle.dispatchEvent(new PointerEvent(type, {bubbles: true, clientY: y, pointerId: 1, button: 0}))
    const start = handle.getBoundingClientRect().top + 10
    window.sikioTop = top + 5
    at('pointerdown', start); at('pointermove', top + 5)
    """)
    # While the pointer is held, the first row already has a transform to make room.
    |> script(
      "return getComputedStyle(document.getElementById('move-#{one}').closest('article')).transform",
      fn transform -> assert transform =~ "matrix", "the first row stays put while held over" end
    )
    |> script("""
    const handle = document.getElementById('move-#{three}')
    handle.dispatchEvent(new PointerEvent('pointerup', {bubbles: true, clientY: window.sikioTop, pointerId: 1, button: 0}))
    """)
    |> eventually(order, equals: Enum.map([three, one, two], &to_string/1))
    # Moves Episode 3 down one position with the arrow key on its handle.
    |> script("document.getElementById('move-#{three}').focus()")
    |> keys(["ArrowDown"])
    |> eventually(order, equals: Enum.map([one, three, two], &to_string/1))
  end

  # ? opens the shortcut overview and Escape closes it. The account menu also opens it.
  # f opens the search, focused and empty. The magnifier button also opens it.
  # Escape clears and closes the search and moves focus to the magnifier.
  test "? shows every key, and f or the magnifier opens the search", %{conn: conn} do
    conn
    |> resize(1440, 900)
    |> open("/all")
    |> assert_has("#entries article", count: 25)
    |> refute_has("#shortcuts[open]")
    |> keys(["?"])
    |> assert_has("#shortcuts[open]", text: "Play or pause")
    |> assert_has("#shortcuts", text: "Previous or next chapter")
    |> assert_has("#entries article:nth-of-type(1) a[aria-current]")
    # Keys typed into the open overview do not reach the page.
    # A `j` dispatched on the body moves the selection by one, and the overview stays open.
    |> keys(["j"])
    |> script(
      "document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'j', bubbles: true}))"
    )
    |> assert_has("#entries article:nth-of-type(2) a[aria-current]")
    |> assert_has("#shortcuts[open]")
    |> keys(["Escape"])
    |> refute_has("#shortcuts[open]")
    |> refute_has("#search-input")
    |> keys(["f"])
    |> assert_has("#search-input")
    |> script("return [document.activeElement.id, document.activeElement.value]", fn
      [id, value] ->
        assert id == "search-input"
        assert value == ""
    end)
    |> fill("#search-input", "Episode 17")
    |> assert_has("#entries article", count: 1)
    |> keys(["Escape"])
    |> assert_has("#entries article", count: 25)
    |> refute_has("#search-input")
    |> script("return document.activeElement.id", fn id ->
      assert id == "toggle-search"
    end)
    |> click("#toggle-search")
    |> assert_has("#search-input")
    |> script("return document.activeElement.id", fn id -> assert id == "search-input" end)
    |> click("#user-menu summary")
    |> click("#show-shortcuts")
    |> assert_has("#shortcuts[open]")
  end

  # The mark-all dialog takes focus when it opens, and Escape closes it.
  # It offers to keep the player's item only while the player has one.
  # Unticking that option lowers the count by one and leaves the item unarchived.
  # The others are archived: still listed under all items, not counted under heard.
  test "the double check marks a list after asking, and may leave the item in the player", %{
    conn: conn
  } do
    # Uses all items, because the playing item moves to the queue and leaves the inbox.
    conn
    |> resize(1440, 900)
    |> open("/all")
    |> click("#mark-all")
    |> assert_has("dialog#mark-all-confirm[open]", text: "40 items in this list")
    # The dialog element takes focus, so no button shows a focus ring before tabbing.
    |> script("return document.activeElement.id", fn id ->
      assert id == "mark-all-confirm"
    end)
    |> refute_has("#mark-all-playing")
    |> keys(["Escape"])
    |> refute_has("#mark-all-confirm")
    |> click("#start-playback")
    |> assert_attached("#player-control[data-entry-id]")
    |> click("#mark-all")
    |> assert_has("#mark-all-playing input[name=playing][type=checkbox]:checked")
    |> click("#mark-all-playing input[name=playing][type=checkbox]")
    |> assert_has("dialog#mark-all-confirm[open]", text: "39 items in this list")
    |> click("#confirm-mark-all")
    |> assert_has("#view-queue-count", text: "1")
    |> assert_has("#entries article:not([data-status=archived])", count: 1)
    |> assert_has("#library-count", text: "40 items")
    |> refute_has("#view-heard-count")
  end

  # Escape closes a subscription's dialog and returns focus to the element that opened it.
  test "the subscriptions page gives the focus back after its dialog", %{
    conn: conn,
    account: account
  } do
    [subscription] = Library.subscriptions(account)

    conn
    |> resize(1440, 900)
    |> open("/subscriptions")
    |> click("#edit-subscription-#{subscription.id}")
    |> assert_has("dialog#edit-subscription-confirm[open]")
    |> keys(["Escape"])
    |> refute_has("#edit-subscription-confirm")
    |> script("return document.activeElement.id", fn id ->
      assert id == "edit-subscription-#{subscription.id}"
    end)
  end

  # A click on an external link without `target` sets `target="_blank"`.
  # So an installed app never loads a foreign page in its own window.
  test "a link away without a target gets target=_blank on click", %{conn: conn} do
    conn
    |> open("/inbox")
    |> script("""
    const link = document.createElement('a')
    link.id = 'away'
    link.href = 'https://example.org/elsewhere'
    link.textContent = 'away'
    document.body.append(link)
    link.addEventListener('click', event => { window.awayTarget = link.target; event.preventDefault() })
    """)
    |> click("#away")
    |> script("return window.awayTarget", fn target -> assert target == "_blank" end)
  end

  # A source gets a tag in its own dialog, which stays open while typing.
  # The tag then appears in the sidebar as its own list.
  # Unsubscribing uses the same dialog, after a confirmation that names the source.
  test "a source is tagged and left from its own list", %{conn: conn} do
    conn
    |> resize(1440, 900)
    |> open("/inbox")
    |> refute_has("#tags-heading")
    |> click("#sidebar a", "Small Hours")
    |> click("#edit-subscription")
    |> assert_has("dialog#edit-subscription-confirm[open]", text: "Small Hours")
    |> fill("#subscription-form input[name=new]", "Must view")
    |> assert_has("dialog#edit-subscription-confirm[open]")
    |> click("#confirm-edit-subscription")
    |> refute_has("#edit-subscription-confirm")
    |> click("#sidebar a", "Must view")
    |> assert_has("#library-heading", text: "Must view")
    |> assert_has("#entries article", count: 25)
    |> click("#sidebar a", "Small Hours")
    |> click("#edit-subscription")
    |> click("#unsubscribe")
    |> assert_has("dialog#unsubscribe-confirm[open]", text: "Unsubscribe from Small Hours?")
    |> keys(["Escape"])
    |> refute_has("#unsubscribe-confirm")
    |> click("#edit-subscription")
    |> click("#unsubscribe")
    |> click("#confirm-unsubscribe")
    |> refute_has("#sidebar a", text: "Small Hours")
    |> assert_has("#library-heading", text: "Queue")
  end

  # From lg the window does not scroll. The list and the detail scroll in separate columns.
  # Scrolling the list leaves the detail in place.
  # Both columns have `tabIndex` 0 for keyboard scrolling.
  # Chrome focuses scroll containers without it, Safari does not.
  # Selecting another item resets the detail to its top.
  # Long notes make every detail overflow its column, whatever the fonts and spacing.
  test "the list and the detail scroll on their own", %{conn: conn} do
    notes = String.duplicate("<p>Something worth reading while it plays.</p>", 40)
    Sikio.Repo.update_all(Sikio.Feeds.Entry, set: [description: notes, description_format: :html])

    conn
    |> resize(1440, 400)
    |> open("/all")
    |> assert_has("#item-detail h2", text: "Episode 40")
    |> script(
      "return ['list-pane', 'item-detail'].map(id => document.getElementById(id).tabIndex)",
      fn indexes -> assert indexes == [0, 0] end
    )
    |> script("""
    window.sikioDetailTop = document.querySelector('#item-detail article').getBoundingClientRect().top
    document.getElementById('list-pane').scrollTop = 1200
    """)
    |> script(
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
    |> script(
      """
      document.getElementById('list-pane').scrollTop = 0
      const detail = document.getElementById('item-detail')
      detail.scrollTop = 150
      return detail.scrollTop
      """,
      fn top -> assert top > 0 end
    )
    |> click("#entries article:nth-of-type(2) a")
    |> assert_has("#item-detail h2", text: "Episode 39")
    |> script("return document.getElementById('item-detail').scrollTop", fn top ->
      assert top == 0
    end)
    # Runs last, because keyboard scrolling is smooth and keeps moving the column afterwards.
    |> script("document.getElementById('item-detail').focus()")
    |> keys([" "])
    |> script(
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
    |> script(
      "return [window.scrollY, Math.round(document.getElementById('list-head').getBoundingClientRect().top)]",
      fn [window, head] ->
        assert window == 0
        assert head == 0
      end
    )
  end

  # The selected row stays visible below the list head.
  # Checked after moving with j and after opening a row's URL far down the list.
  test "the chosen row stays in view", %{conn: conn} do
    conn
    |> resize(1440, 500)
    |> open("/all")
    |> assert_has("#item-detail h2", text: "Episode 40")
    |> keys(List.duplicate("j", 6))
    |> assert_has("#item-detail h2", text: "Episode 34")
    |> script(in_view("#entries article:nth-of-type(7)"), fn [below_head, above_end] ->
      assert below_head >= 0, "the row is not under the list's head"
      assert above_end >= 0, "the row is not cut off at the window's end"
    end)
    |> then(fn conn ->
      href =
        conn
        |> assert_has("#entries article:nth-of-type(20) a")
        |> value_of(
          "return document.querySelector('#entries article:nth-of-type(20) a').getAttribute('href')"
        )

      open(conn, href)
    end)
    |> assert_has("#item-detail h2", text: "Episode 21")
    |> script(
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
  test "a wide screen shows the first item, a phone the list", %{conn: conn} do
    conn
    |> resize(1440, 900)
    |> open("/all")
    |> assert_has("#item-detail h2", text: "Episode 40")
    |> resize(500, 900)
    |> open("/all")
    # An absence check before the socket connects proves nothing.
    # The hook pushes its event only after connecting.
    # Events are handled in order, so once the search opens, the hook's mount event is handled.
    |> assert_has("[data-phx-main].phx-connected")
    |> assert_has("#entries article", count: 25)
    |> keys(["f"])
    |> assert_has("#search-input")
    |> refute_has("#item-detail h2")
  end

  test "the list loads the next batch when its end comes into view", %{conn: conn} do
    conn
    |> resize(1440, 900)
    |> open("/all")
    |> assert_has("#entries article", count: 25)
    |> script("document.querySelector('#entries article:last-child').scrollIntoView()")
    |> assert_has("#entries article", count: 40)
  end

  # An item opened deep in the list loads with a window around it. Scrolling to the window's
  # top loads the batch above, and the row that was first stays where the reader sees it.
  test "the list loads the batch above when its top comes into view", context do
    # At this height the fourteen rows above push the first row out of view.
    conn =
      context.conn
      |> resize(1440, 500)
      |> open(item_path(episode(context.account, "Episode 1")))
      |> assert_has("#item-detail h2", text: "Episode 1")
      |> assert_has("#entries article", count: 26)

    first = value_of(conn, @first_row)

    conn
    |> script("document.getElementById('list-pane').scrollTop = 0")
    |> assert_has("#entries article", count: 40)
    |> script("return document.getElementById('list-pane').scrollTop", fn scrolled ->
      assert scrolled > 0, "the list jumped to its new top"
    end)
    |> script(
      "#{@frames}\nreturn frame().then(frame).then(() => { #{in_view("#" <> first)} })",
      fn [below_head, above_end] ->
        assert below_head >= -1, "the row that was first is hidden under the list's head"
        assert above_end >= 0, "the row that was first is cut off at the window's end"
      end
    )
  end

  # On a phone the page scrolls instead of the list pane, and the back link keeps the window.
  test "a phone's list loads the batch above when its top comes into view", context do
    conn =
      context.conn
      |> resize(390, 844)
      |> open(item_path(episode(context.account, "Episode 1")))
      |> assert_has("#item-detail h2", text: "Episode 1")
      |> click("#nav-back")
      |> assert_has("#entries article", count: 26)

    first = value_of(conn, @first_row)

    conn
    # A scroll event fires only on a change, so the page leaves its top before it returns.
    # Both scrolls in one frame would cancel out, so the second waits for two frames.
    |> script("""
    #{@frames}
    window.scrollTo(0, document.body.scrollHeight)
    return frame().then(frame).then(() => window.scrollTo(0, 0))
    """)
    |> assert_has("#entries article", count: 40)
    |> script(
      """
      #{@frames}
      return frame().then(frame).then(() => {
        const row = document.getElementById('#{first}').getBoundingClientRect()
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

  # The history's calendar opens from the head on a phone and fits its width.
  test "a phone's history filters by a day from the calendar", context do
    Sikio.Playback.mark(context.account, episode(context.account, "Episode 1").id, :heard)

    layout = """
    const calendar = document.getElementById('history-calendar')
    const day = document.querySelector('#history-calendar a[id^=calendar-day-]')
    return [getComputedStyle(calendar).display, document.documentElement.scrollWidth,
      window.innerWidth, Math.round(day.getBoundingClientRect().width),
      getComputedStyle(day).backgroundColor]
    """

    context.conn
    |> resize(390, 844)
    |> open("/history")
    |> script(
      "return getComputedStyle(document.getElementById('history-calendar')).display",
      &assert(&1 == "none")
    )
    |> click("#toggle-calendar")
    |> assert_has("#history-calendar a[id^=calendar-day-]", count: 1)
    |> script(layout, fn [display, scroll_width, width, size, background] ->
      assert display == "block"
      assert scroll_width <= width, "the calendar widens the page"
      assert size == 36
      assert background == "rgba(0, 0, 0, 0)"
    end)
    |> click("#history-calendar a[id^=calendar-day-]")
    |> assert_has("#calendar-clear")
    |> assert_has("#entries article", count: 1)
    |> script(layout, fn [display, _, _, _, background] ->
      assert display == "block"
      refute background == "rgba(0, 0, 0, 0)", "the selected day is not highlighted"
    end)
    |> click("#calendar-clear")
    |> refute_has("#calendar-clear")
    |> assert_has("#entries article", count: 1)
  end
end
