# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryTest do
  @moduledoc """
  The library's list in a real browser, where scrolling is what asks for more.

  `Phoenix.LiveViewTest` can send the event a viewport sends, but not whether the browser sends
  it when the list's end comes into view.
  """
  use SikioWeb.FeatureCase

  import Ecto.Query

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
    %{account: account}
  end

  # The queue's rows move by their handles: dragged, or a place at a time with the arrow keys.
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
    # Episode 3 dragged above the first row.
    |> execute_script("""
    const handle = document.getElementById('move-#{three}')
    const top = document.getElementById('move-#{one}').getBoundingClientRect().top
    const at = (type, y) => handle.dispatchEvent(new PointerEvent(type, {bubbles: true, clientY: y, pointerId: 1, button: 0}))
    const start = handle.getBoundingClientRect().top + 10
    window.sikioTop = top + 5
    at('pointerdown', start); at('pointermove', top + 5)
    """)
    # While it is held, the row it would push aside has made room already.
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
    # Episode 3 a place down by its handle's arrow key.
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
  # second answer archives the list: still among all items, never among what was heard.
  feature "the double check marks a list after asking", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/inbox")
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
    |> assert_has(css("#view-all-count", text: "40"))
    |> assert_has(css("#view-heard-count", count: 0))
  end

  # The dialog offers to leave the player's item only while the player holds one. Unticked, it
  # counts one fewer and that item stays as it was.
  feature "the double check may leave the item in the player", %{session: session} do
    # All items, since the item that plays stands in the queue and no longer in the inbox.
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> click(css("#mark-all"))
    |> assert_has(css("dialog#mark-all-confirm[open]", text: "40 items in this list"))
    |> refute_has(css("#mark-all-playing"))
    |> send_keys([:escape])
    |> click(css("#start-playback"))
    |> assert_has(css("#player-control[data-entry-id]"))
    |> click(css("#mark-all"))
    |> assert_has(css("#mark-all-playing input[name=playing][type=checkbox]:checked"))
    |> click(css("#mark-all-playing input[name=playing][type=checkbox]"))
    |> assert_has(css("dialog#mark-all-confirm[open]", text: "39 items in this list"))
    |> click(css("#confirm-mark-all"))
    |> assert_has(css("#view-queue-count", text: "1"))
    |> assert_has(css("#entries article:not([data-status=archived])", count: 1))
  end

  # Leaving a source stands at the left of the dialog's buttons, apart from cancelling and saving,
  # and the dialog is wide enough for its fields.
  feature "a source's dialog leads out of the subscription from its button row", %{
    session: session
  } do
    session
    |> resize_window(1440, 900)
    |> open("/inbox")
    |> click(css("#sidebar a", text: "Small Hours"))
    |> click(css("#edit-subscription"))
    |> assert_has(css("dialog#edit-subscription-confirm[open]"))
    |> execute_script(
      """
      const box = id => document.getElementById(id).getBoundingClientRect()
      const leave = box('unsubscribe'), cancel = box('cancel-edit-subscription')
      return [Math.round(box('edit-subscription-confirm').width),
              Math.abs(leave.top + leave.height / 2 - cancel.top - cancel.height / 2) < 2,
              leave.right < cancel.left]
      """,
      fn [width, same_row, left] ->
        assert width >= 512
        assert same_row, "leaving shares the row of the buttons"
        assert left, "leaving stands left of cancelling"
      end
    )
  end

  # Closed with Escape, a subscription's dialog hands the focus back to the row that opened it.
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
    |> refute_has(css("#edit-subscription-confirm"))
    |> execute_script("return document.activeElement.id", fn id ->
      assert id == "edit-subscription-#{subscription.id}"
    end)
  end

  # A link away from Sikio that names no target is still sent to a tab of its own, so an installed
  # app never loads a stranger's page in its own window.
  feature "a link away without a target opens in a tab of its own", %{session: session} do
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

  # The page to add a source centres its one field, as a search page does.
  feature "the field to add a source stands in the middle of the page", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/add")
    |> execute_script(
      """
      const box = el => el.getBoundingClientRect()
      const form = box(document.getElementById('add-form'))
      const main = box(document.getElementById('add-form').closest('main'))
      const middle = main.left + main.width / 2
      const centre = el => Math.round(el.left + el.width / 2 - middle)
      const range = document.createRange()
      range.selectNodeContents(document.getElementById('add-subtitle'))
      const hint = [...document.querySelectorAll('#add-hint > *')].map(line => line.getClientRects().length)
      return [centre(form), Math.round(form.width), Math.round(main.width), centre(range.getBoundingClientRect()), hint]
      """,
      fn [offset, form, main, subtitle, hint] ->
        assert abs(offset) <= 2, "the field sits #{offset}px off the middle"
        assert form < main
        assert abs(subtitle) <= 2, "the subtitle sits #{subtitle}px off the middle"
        assert hint == [1, 1], "each sentence of the hint keeps a line of its own"
      end
    )
  end

  # Typing offers a way to clear the field, which leaves the focus there for the next search.
  feature "the field to add a source clears and keeps the focus", %{session: session} do
    session
    |> open("/add")
    |> refute_has(css("#clear-search"))
    |> fill_in(css("#add-q"), with: "small hours")
    |> assert_has(css("#clear-search"))
    |> click(css("#clear-search"))
    |> refute_has(css("#clear-search"))
    |> execute_script(
      "return [document.getElementById('add-q').value, document.activeElement.id]",
      fn [value, focused] ->
        assert value == ""
        assert focused == "add-q"
      end
    )
  end

  # A source is given a tag in its own dialog, which stays open while it is typed in, and the tag
  # then stands in the sidebar as a place of its own.
  feature "a source is given a tag from its own list", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/inbox")
    |> refute_has(css("#tags-heading"))
    |> click(css("#sidebar a", text: "Small Hours"))
    |> click(css("#edit-subscription"))
    |> assert_has(css("dialog#edit-subscription-confirm[open]", text: "Small Hours"))
    |> fill_in(css("#subscription-form input[name=new]"), with: "Must view")
    |> assert_has(css("dialog#edit-subscription-confirm[open]"))
    |> click(css("#confirm-edit-subscription"))
    # refute_has fails at once while the dialog is still there; a count of none waits for it.
    |> assert_has(css("#edit-subscription-confirm", count: 0))
    |> click(css("#sidebar a", text: "Must view"))
    |> assert_has(css("#library-heading", text: "Must view"))
    |> assert_has(css("#entries article", count: 25))
  end

  # A long name has the head's whole width: the actions stand in the line beneath it.
  feature "the list's actions stand beneath its heading", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/inbox")
    |> click(css("#sidebar a", text: "Small Hours"))
    |> assert_has(css("#edit-subscription"))
    |> execute_script(
      """
      const box = id => document.getElementById(id).getBoundingClientRect()
      const head = document.querySelector('#list-head > div').getBoundingClientRect()
      const padding = parseFloat(getComputedStyle(document.querySelector('#list-head > div')).paddingRight)
      return [box('toggle-search').top >= box('library-heading').bottom,
              Math.round(head.right - padding - box('library-heading').right)]
      """,
      fn [beneath, gap] ->
        assert beneath, "the actions stand beside the heading"
        assert gap == 0, "the heading does not have the head's whole width"
      end
    )
  end

  # On a phone the large heading gives way to a title in the bar once it scrolls under it.
  feature "a phone's bar takes the title once the heading has scrolled away", %{session: session} do
    session
    |> resize_window(390, 844)
    |> open("/inbox")
    |> assert_has(css("#entries article", count: 25))
    |> refute_has(css("#app-header[data-shrunk]"))
    |> execute_script("window.scrollTo(0, 600)")
    |> assert_has(css("#app-header[data-shrunk]"))
    # The title fades in, so the script waits up to a second for it to show in full.
    |> execute_script(
      """
      const title = document.getElementById('nav-title'), until = performance.now() + 1000
      return new Promise(function wait(resolve) {
        const opacity = getComputedStyle(title).opacity
        if (opacity === '1' || performance.now() > until) resolve(opacity)
        else requestAnimationFrame(() => wait(resolve))
      })
      """,
      fn opacity -> assert opacity == "1" end
    )
    |> execute_script("window.scrollTo(0, 0)")
    |> assert_has(css("#app-header:not([data-shrunk])"))
  end

  # A source is left from its own dialog, after a question that names it.
  feature "a source is left from its own list", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/inbox")
    |> click(css("#sidebar a", text: "Small Hours"))
    |> click(css("#edit-subscription"))
    |> click(css("#unsubscribe"))
    |> assert_has(css("dialog#unsubscribe-confirm[open]", text: "Unsubscribe from Small Hours?"))
    |> send_keys([:escape])
    |> refute_has(css("#unsubscribe-confirm"))
    |> click(css("#edit-subscription"))
    |> click(css("#unsubscribe"))
    |> click(css("#confirm-unsubscribe"))
    |> refute_has(css("#sidebar a", text: "Small Hours"))
    |> assert_has(css("#library-heading", text: "Inbox"))
  end

  # A date heading sticks beneath the list's head while its group scrolls past.
  feature "date headings stick beneath the list's head", %{session: session} do
    now = DateTime.utc_now()

    for {entry, n} <- Enum.with_index(Sikio.Repo.all(Sikio.Feeds.Entry)) do
      entry
      |> Ecto.Changeset.change(published_at: DateTime.add(now, -n * 6, :day))
      |> Sikio.Repo.update!()
    end

    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#group-today"))
    |> execute_script("document.getElementById('list-pane').scrollTop = 900")
    |> execute_script(
      """
      const head = document.getElementById('list-head').getBoundingClientRect().bottom
      return [...document.querySelectorAll('#entries [data-group]')]
        .some(h => Math.abs(h.getBoundingClientRect().top - head) < 1)
      """,
      fn stuck -> assert stuck, "no heading stands beneath the list's head" end
    )
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
    |> click(css("#entries article:nth-of-type(2) a"))
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
      "return document.querySelector('#entries article:nth-of-type(20) a').getAttribute('href')",
      fn href -> Process.put(:href, href) end
    )
    |> then(&open(&1, Process.delete(:href)))
    |> assert_has(css("#item-detail h2", text: "Episode 21"))
    |> execute_script(
      """
      const frame = () => new Promise(resolve => requestAnimationFrame(resolve))
      return frame().then(frame).then(() => {
        const row = document.querySelector('#entries article:nth-of-type(20)').getBoundingClientRect()
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
      const row = document.querySelector('#entries article:nth-of-type(7)').getBoundingClientRect()
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
    |> click(css("#entries article:first-of-type a"))
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
