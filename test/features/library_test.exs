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
    account = signed_in(session, "ada")
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
  # opens it without a keyboard, and Escape closes it. f opens the search, beside j, k and m, and
  # the f is not typed into it. The magnifier opens it too, and Escape clears it and folds it away.
  feature "? shows every key, and f or the magnifier opens the search", %{session: session} do
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#entries article", count: 25))
    |> gone(css("#shortcuts[open]"))
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

  # The double check asks in a dialog that opens as it appears and takes the focus. Escape lets
  # go of it. It offers to leave the player's item only while the player holds one; unticked, it
  # counts one fewer and that item stays as it was. The rest is archived: still among all items,
  # never among what was heard.
  feature "the double check marks a list after asking, and may leave the item in the player", %{
    session: session
  } do
    # All items, since the item that plays stands in the queue and no longer in the inbox.
    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> click(css("#mark-all"))
    |> assert_has(css("dialog#mark-all-confirm[open]", text: "40 items in this list"))
    # The dialog takes the focus itself, so no button shows a ring before anybody tabs to it.
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
    |> assert_has(css("#view-all-count", text: "40"))
    |> gone(css("#view-heard-count"))
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
    |> gone(css("#edit-subscription-confirm"))
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

  # A source is given a tag in its own dialog, which stays open while it is typed in, and the tag
  # then stands in the sidebar as a place of its own. The source is left from the same dialog,
  # after a question that names it.
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
    |> assert_has(css("#library-heading", text: "Inbox"))
  end

  # From lg the window stands still. The list and the detail each scroll in their own column, and
  # the other stays where it is. Each column takes the keyboard's focus to be scrolled: Chrome lets
  # a scroll box take it unasked, Safari does not, so both stand in the tab order. Another item
  # starts at its top, not where the last one was left.
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
    # Back at the top, so the row is not under the list's head when it is clicked. The detail is
    # left scrolled, so the next item has a place to start from other than its top.
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
    # Last, because a key scrolls smoothly and goes on moving the column after it moved.
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

  # The chosen row stays in view beneath the list's head: moved to with j and k, or opened by its
  # address far down the list.
  feature "the chosen row stays in view", %{session: session} do
    session
    |> resize_window(1440, 500)
    |> open("/all")
    |> assert_has(css("#item-detail h2", text: "Episode 40"))
    |> send_keys(List.duplicate("j", 6))
    |> assert_has(css("#item-detail h2", text: "Episode 34"))
    |> execute_script(in_view(7), fn [below_head, above_end] ->
      assert below_head >= 0, "the row is not under the list's head"
      assert above_end >= 0, "the row is not cut off at the window's end"
    end)
    |> then(fn session ->
      href = session |> find(css("#entries article:nth-of-type(20) a")) |> Element.attr("href")
      open(session, href)
    end)
    |> assert_has(css("#item-detail h2", text: "Episode 21"))
    |> execute_script(
      # The row is scrolled to once the list has laid out, a frame or two after the page.
      """
      const frame = () => new Promise(resolve => requestAnimationFrame(resolve))
      return frame().then(frame).then(() => { #{in_view(20)} })
      """,
      fn [below_head, above_end] ->
        assert below_head >= 0, "the opened row is not under the list's head"
        assert above_end >= 0, "the opened row is not cut off at the window's end"
      end
    )
  end

  defp in_view(nth) do
    """
    const row = document.querySelector('#entries article:nth-of-type(#{nth})').getBoundingClientRect()
    const head = document.getElementById('list-head').getBoundingClientRect()
    return [Math.round(row.top - head.bottom), Math.round(window.innerHeight - row.bottom)]
    """
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
    # Absent before the page connects proves nothing; the hook only asks once it has. A search
    # opened after that answers after anything the hook asked on mounting.
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
end
