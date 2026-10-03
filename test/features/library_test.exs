# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryTest do
  @moduledoc """
  The library's list in a real browser, where scrolling is what asks for more.

  `Phoenix.LiveViewTest` can send the event a viewport sends, but not whether the browser sends
  it when the list's end comes into view.
  """
  use SikioWeb.FeatureCase

  import Sikio.FeedFixtures

  alias Sikio.Feeds.Parser
  alias Sikio.Library

  setup %{session: session} do
    account = signed_up(session, "ada")
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")

    entries =
      for n <- 1..40,
          do: %{hd(preview.entries) | external_id: "episode-#{n}", title: "Episode #{n}"}

    {:ok, _} = Library.subscribe(account, %{preview | entries: entries})
    :ok
  end

  # Every key in one place: ? opens the overview from anywhere outside a field, the account menu
  # opens it without a keyboard, and Escape closes it.
  feature "? shows every key", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#entries article", count: 25))
    |> refute_has(css("#shortcuts[open]"))
    # Chromedriver types ? as Shift and an underscore. A keyboard sends the character itself, in
    # whichever layout puts it where, and that is what the page reads.
    |> execute_script(
      "document.body.dispatchEvent(new KeyboardEvent('keydown', {key: '?', shiftKey: true, bubbles: true}))"
    )
    |> assert_has(css("#shortcuts[open]", text: "Play or pause"))
    |> assert_has(css("#shortcuts", text: "Previous or next chapter"))
    |> assert_has(css("#entries article:nth-of-type(1) a[aria-current]"))
    # The open overview keeps the keys from the page behind it. A key from outside it moves the
    # list by one, and the page that follows leaves the overview open.
    |> send_keys(["j"])
    |> execute_script(
      "document.body.dispatchEvent(new KeyboardEvent('keydown', {key: 'j', bubbles: true}))"
    )
    |> assert_has(css("#entries article:nth-of-type(2) a[aria-current]"))
    |> assert_has(css("#shortcuts[open]"))
    |> send_keys([:escape])
    |> assert_has(css("#shortcuts[open]", count: 0))
    |> click(css("#user-menu summary"))
    |> click(css("#show-shortcuts"))
    |> assert_has(css("#shortcuts[open]"))
  end

  # What the footer said lives in an overview the account menu opens: the name, the tagline and
  # the offer of the source code.
  feature "the account menu tells about Sikio", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> refute_has(css("#about[open]"))
    |> click(css("#user-menu summary"))
    |> click(css("#show-about"))
    |> assert_has(css("#about[open]", text: "A little more intention. A little less autoplay."))
    |> assert_has(css("#about[open]", text: "Your personal media library"))
    |> assert_has(css("#about[open] a", text: "Source code"))
    |> refute_has(css("#user-menu[open]"))
    |> send_keys([:escape])
    |> assert_has(css("#about[open]", count: 0))
  end

  # The double check asks in a dialog that opens as it appears. Escape lets go of it, and the
  # second answer marks the list.
  feature "the double check marks a list after asking", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/new")
    |> click(css("#mark-all"))
    |> assert_has(css("dialog#mark-all-confirm[open]", text: "40 items in this list"))
    # The dialog takes the focus itself, so no button shows a ring before anybody tabs to it.
    |> execute_script("return document.activeElement.id", fn id ->
      assert id == "mark-all-confirm"
    end)
    |> send_keys([:escape])
    |> refute_has(css("#mark-all-confirm"))
    |> click(css("#mark-all"))
    |> click(css("#confirm-mark-all"))
    |> refute_has(css("#entries article"))
    |> assert_has(css("#view-completed-count", text: "40"))
  end

  # The search folds away behind the magnifier. Opened, the field takes the keyboard, so typing
  # j or k searches rather than moves; Escape clears it and folds it away again.
  feature "the magnifier opens a search that narrows the list", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#entries article", count: 25))
    |> refute_has(css("#search-input"))
    |> click(css("#toggle-search"))
    |> assert_has(css("#search-input"))
    |> execute_script("return document.activeElement.id", fn id -> assert id == "search-input" end)
    |> fill_in(css("#search-input"), with: "Episode 17")
    |> assert_has(css("#entries article", count: 1))
    |> send_keys([:escape])
    |> assert_has(css("#entries article", count: 25))
    |> refute_has(css("#search-input"))
    |> execute_script("return document.activeElement.id", fn id ->
      assert id == "toggle-search"
    end)
  end

  # f opens the search from the keyboard, beside j, k and m, and the f is not typed into it.
  feature "f opens the search and puts the cursor in it", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#entries article", count: 25))
    |> send_keys(["f"])
    |> assert_has(css("#search-input"))
    |> execute_script("return [document.activeElement.id, document.activeElement.value]", fn
      [id, value] ->
        assert id == "search-input"
        assert value == ""
    end)
  end

  # From lg the window stands still. The list scrolls in its own column beneath its head, and the
  # detail beside it stays where it is.
  feature "the list scrolls on its own beneath its head", %{session: session} do
    session
    |> resize_window(1440, 700)
    |> open("/all")
    |> assert_has(css("#entries article", count: 25))
    |> assert_has(css("#item-detail h2"))
    |> execute_script("document.getElementById('list-pane').scrollTop = 1200")
    |> execute_script(
      """
      const top = id => Math.round(document.getElementById(id).getBoundingClientRect().top)
      return [document.getElementById('list-pane').scrollTop, window.scrollY, top('list-head'),
              Math.round(document.querySelector('#item-detail article').getBoundingClientRect().top),
              document.documentElement.scrollHeight - window.innerHeight]
      """,
      fn [list, window, head, title, page_room] ->
        assert list > 0
        assert window == 0
        assert head == 0
        assert title < 200, "the detail does not move with the list"
        assert page_room <= 0, "the page itself has nothing to scroll"
      end
    )
  end

  # Long notes scroll in the detail's column, and the list beside it stays where it is. Another
  # item starts at its top, not where the last one was left.
  feature "the detail scrolls on its own and starts at the top", %{session: session} do
    session
    |> resize_window(1440, 400)
    |> open("/all")
    |> assert_has(css("#item-detail h2", text: "Episode 40"))
    |> execute_script("document.getElementById('item-detail').scrollTop = 150")
    |> execute_script(
      "return [document.getElementById('item-detail').scrollTop, window.scrollY, Math.round(document.getElementById('list-head').getBoundingClientRect().top)]",
      fn [detail, window, head] ->
        assert detail > 0
        assert window == 0
        assert head == 0
      end
    )
    |> click(css("#entries article:nth-child(2) a"))
    |> assert_has(css("#item-detail h2", text: "Episode 39"))
    |> execute_script("return document.getElementById('item-detail').scrollTop", fn top ->
      assert top == 0
    end)
  end

  # The window no longer scrolls, so each column takes the keyboard's focus to be scrolled. Chrome
  # lets a scroll box take it unasked, Safari does not, so both stand in the tab order.
  feature "the keyboard scrolls a column it has focused", %{session: session} do
    session
    |> resize_window(1440, 400)
    |> open("/all")
    |> assert_has(css("#item-detail h2", text: "Episode 40"))
    |> execute_script(
      "return ['list-pane', 'item-detail'].map(id => document.getElementById(id).tabIndex)",
      fn indexes -> assert indexes == [0, 0] end
    )
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
  end

  # Opened by its address, an item far down the list has its row in view beside it.
  feature "an item opened by its address has its row in view", %{session: session} do
    session
    |> resize_window(1440, 500)
    |> open("/all")
    |> assert_has(css("#entries article", count: 25))
    |> execute_script(
      "return document.querySelector('#entries article:nth-child(20) a').getAttribute('href')",
      fn href -> Process.put(:href, href) end
    )
    |> then(&open(&1, Process.delete(:href)))
    |> assert_has(css("#item-detail h2", text: "Episode 21"))
    |> execute_script(
      """
      const frame = () => new Promise(resolve => requestAnimationFrame(resolve))
      return frame().then(frame).then(() => {
        const row = document.querySelector('#entries article:nth-child(20)').getBoundingClientRect()
        const head = document.getElementById('list-head').getBoundingClientRect()
        return [Math.round(row.top - head.bottom), Math.round(window.innerHeight - row.bottom)]
      })
      """,
      fn [below_head, above_end] ->
        assert below_head >= 0
        assert above_end >= 0
      end
    )
  end

  # Neither the page nor a column springs back at its end, and so Safari has no page to pull.
  feature "nothing bounces at the end of a scroll", %{session: session} do
    session
    |> resize_window(1440, 700)
    |> open("/all")
    |> assert_has(css("#item-detail h2"))
    |> execute_script(
      """
      const behavior = el => getComputedStyle(el).overscrollBehaviorY
      return [behavior(document.documentElement), behavior(document.getElementById('list-pane')),
              behavior(document.getElementById('item-detail'))]
      """,
      fn behaviors -> assert behaviors == ["none", "none", "none"] end
    )
  end

  # Moving with j and k keeps the chosen row in view, beneath the list's head.
  feature "the keyboard keeps the chosen row in view", %{session: session} do
    session
    |> resize_window(1440, 500)
    |> open("/all")
    |> assert_has(css("#item-detail h2", text: "Episode 40"))
    |> send_keys(List.duplicate("j", 6))
    |> assert_has(css("#item-detail h2", text: "Episode 34"))
    |> execute_script(
      """
      const row = document.querySelector('#entries article:nth-child(7)').getBoundingClientRect()
      const head = document.getElementById('list-head').getBoundingClientRect()
      return [Math.round(row.top - head.bottom), Math.round(window.innerHeight - row.bottom)]
      """,
      fn [below_head, above_end] ->
        assert below_head >= 0, "the row is not under the list's head"
        assert above_end >= 0, "the row is not cut off at the window's end"
      end
    )
  end

  # Long lines read badly. The card keeps the column's width, and the notes inside it stop at
  # about eighty characters, a block in the middle of the card, its text set from the left.
  feature "the notes read at a measure of about eighty characters", %{session: session} do
    session
    |> resize_window(1600, 900)
    |> open("/all")
    |> click(css("#entries article:first-child a"))
    |> assert_has(css("#item-notes"))
    |> execute_script(
      """
      const column = document.getElementById('item-detail')
      const card = column.querySelector('article').getBoundingClientRect()
      const notes = document.getElementById('item-notes')
      const box = notes.getBoundingClientRect()
      const inner = column.getBoundingClientRect()
      return [Math.round(card.width), Math.round(inner.width), Math.round(box.width),
              Math.round(box.left - card.left), Math.round(card.right - box.right),
              getComputedStyle(column.querySelector('article h2')).fontSize, getComputedStyle(notes).textAlign]
      """,
      fn [card, column, width, left, right, size, align] ->
        assert card > column - 80, "the card keeps the column's width"
        assert width < card - 100, "the notes stop short of the card's width"
        assert abs(left - right) <= 1
        assert size == "26px"
        assert align in ["start", "left"]
      end
    )
  end

  # Beside the list there is room for the detail, so a wide screen shows the first item. A phone
  # stays on the list, where a chosen item would cover it.
  feature "a wide screen shows the first item, a phone the list", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#item-detail h2", text: "Episode 40"))
    |> resize_window(500, 900)
    |> open("/all")
    # Absent before the page connects proves nothing; the hook only asks once it has.
    |> assert_has(css("[data-phx-main].phx-connected"))
    |> assert_has(css("#entries article", count: 25))
    |> refute_has(css("#item-detail h2"))
  end

  feature "the list loads the next batch when its end comes into view", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#entries article", count: 25))
    |> execute_script("document.querySelector('#entries article:last-child').scrollIntoView()")
    |> assert_has(css("#entries article", count: 40))
  end
end
