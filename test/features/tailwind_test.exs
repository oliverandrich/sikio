# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.TailwindTest do
  use SikioWeb.FeatureCase

  alias Sikio.FeedFixtures
  alias Sikio.Feeds.Parser
  alias Sikio.Library

  # Sikio's own grounds, Tailwind's neutral-50 and neutral-950, read from the browser rather than from
  # the markup: a class name proves nothing about what a stylesheet finally resolves to. A palette
  # retune in Tailwind changes these values, which is worth noticing.
  @ground "oklch(0.985 0 none)"
  @dark_ground "oklch(0.145 0 none)"

  feature "styles follow system changes and ignore an old stored theme", %{session: session} do
    session
    |> system_scheme("light")
    |> open("/")
    |> execute_script("localStorage.setItem('phx:theme', 'dark')")
    |> open("/")
    |> execute_script("return getComputedStyle(document.body).backgroundColor", fn color ->
      assert color == @ground
    end)
    |> refute_has(css("[data-phx-theme]"))
    |> execute_script(
      "return getComputedStyle(document.querySelector('#setup-code-form button')).display",
      fn display ->
        assert display == "inline-flex"
      end
    )
    |> system_scheme("dark")
    |> execute_script("return getComputedStyle(document.body).colorScheme", fn scheme ->
      assert scheme == "dark"
    end)
    |> execute_script("return getComputedStyle(document.body).backgroundColor", fn color ->
      assert color == @dark_ground
    end)
    |> system_scheme("light")
    |> execute_script("return getComputedStyle(document.body).backgroundColor", fn color ->
      assert color == @ground
    end)
  end

  # The name reads as body text and the dot after it carries the signal, a different shade once the
  # page turns dark. Shades are left to Tailwind here; the grounds above are pinned.
  feature "the wordmark's dot carries the signal colour and adapts to the scheme", %{
    session: session
  } do
    session
    |> system_scheme("light")
    |> open("/")
    |> execute_script(wordmark(), fn [name, dot, text] ->
      assert name == text
      refute dot in [text, "rgba(0, 0, 0, 0)"]
    end)
    |> execute_script(wordmark(), fn [_name, light, _text] ->
      session
      |> system_scheme("dark")
      |> execute_script(wordmark(), fn [_name, dark, _text] -> refute dark == light end)
    end)
  end

  # Durations, dates and counts are set in the mono, which a browser only loads once something
  # asks for it. A family that never loaded falls back to a system face without an error.
  feature "metadata is set in IBM Plex Mono, and the face is loaded", %{session: session} do
    account = signed_up(session, "ada")

    {:ok, preview} =
      Parser.parse(FeedFixtures.podcast(), "https://example.org/rss")

    {:ok, _} = Library.subscribe(account, preview)
    [entry] = Library.entries(account)

    session
    |> open("/")
    |> assert_has(css("#runtime-#{entry.id}"))
    |> execute_script(
      """
      const runtime = getComputedStyle(document.querySelector('#runtime-#{entry.id}')).fontFamily
      return document.fonts.ready.then(() => [runtime, document.fonts.check('500 12px "IBM Plex Mono"')])
      """,
      fn [family, loaded] ->
        assert family =~ ~r/^"IBM Plex Mono"/
        assert loaded
      end
    )
  end

  # The entry the reader is on reads as the accent, with its count as a tinted pill. A tint on its
  # own all but vanishes against the light ground.
  feature "the active navigation entry carries the accent", %{session: session} do
    signed_up(session, "ada")

    session
    |> resize_window(1440, 900)
    |> open("/subscriptions")
    |> execute_script(
      """
      const probe = document.createElement('span')
      probe.className = 'text-accent'
      document.body.append(probe)
      const color = el => getComputedStyle(el).color
      return [color(probe), color(document.getElementById('subscriptions-heading')),
              color(document.getElementById('view-all'))]
      """,
      fn [accent, active, inactive] ->
        assert active == accent
        refute inactive == accent
      end
    )
  end

  # Ink marks actions and the current place. A source's name is neither, so it reads muted, and the
  # chosen item stands out by its ground alone.
  feature "a source's name reads muted and the chosen item has no edge", %{session: session} do
    account = signed_up(session, "ada")
    {:ok, preview} = Parser.parse(FeedFixtures.podcast(), "https://example.org/rss")
    {:ok, _} = Library.subscribe(account, preview)
    [entry] = Library.entries(account)

    session
    |> resize_window(1440, 900)
    |> open("/inbox")
    |> click(css("#play-#{entry.id}"))
    |> assert_has(css("#play-#{entry.id}[aria-current=true]"))
    |> execute_script(
      """
      const probe = document.createElement('span')
      probe.className = 'text-muted'
      document.body.append(probe)
      const style = el => getComputedStyle(el)
      return [style(probe).color, style(document.querySelector('[data-source]')).color,
              style(document.getElementById('entries-#{entry.id}')).boxShadow]
      """,
      fn [muted, source, edge] ->
        assert source == muted
        assert edge == "none"
      end
    )
  end

  # Black text alone does not read as a link, so links in running text are underlined.
  feature "a link in running text is underlined", %{session: session} do
    signed_up(session, "ada")

    session
    |> open("/subscriptions")
    |> execute_script(
      "return getComputedStyle(document.getElementById('opml-import-link')).textDecorationLine",
      fn line -> assert line == "underline" end
    )
  end

  # The current segment is filled with ink. A dialog stands on a hairline edge, and the question
  # before leaving a source answers in the danger colour.
  feature "segments, dialogs and a destructive answer carry their colours", %{session: session} do
    account = signed_up(session, "ada")
    {:ok, preview} = Parser.parse(FeedFixtures.podcast(), "https://example.org/rss")
    {:ok, _} = Library.subscribe(account, preview)

    probe = fn class ->
      """
      const probe = document.createElement('span')
      probe.className = '#{class}'
      document.body.append(probe)
      return getComputedStyle(probe).backgroundColor
      """
    end

    background = fn id ->
      "return getComputedStyle(document.getElementById('#{id}')).backgroundColor"
    end

    session
    |> resize_window(1440, 900)
    |> open("/inbox")
    |> click(css("#sidebar a", text: "Small Hours"))
    |> assert_has(css("#filter-status-inbox[aria-current=true]"))
    |> execute_script(probe.("bg-accent"), fn accent ->
      session
      |> execute_script(background.("filter-status-inbox"), fn current ->
        assert current == accent
      end)
    end)
    |> click(css("#edit-subscription"))
    |> assert_has(css("dialog#edit-subscription-confirm[open]"))
    |> execute_script(
      "return getComputedStyle(document.getElementById('edit-subscription-confirm')).borderTopWidth",
      fn width -> assert width == "1px" end
    )
    |> click(css("#unsubscribe"))
    |> assert_has(css("dialog#unsubscribe-confirm[open]"))
    |> execute_script(probe.("bg-danger"), fn danger ->
      session
      |> execute_script(background.("confirm-unsubscribe"), fn answer ->
        assert answer == danger
      end)
    end)
  end

  # A dialog keeps to quiet sizes from sm: a short title, buttons of 36px and its answers in a band
  # of their own at the foot. A form stands further from the title than a question.
  feature "a dialog keeps quiet sizes beside a mouse", %{session: session} do
    feed = subscribed(session)

    session
    |> resize_window(1440, 900)
    |> open("/feeds/#{feed}")
    |> click(css("#edit-subscription"))
    |> assert_has(css("dialog#edit-subscription-confirm[open]"))
    |> execute_script(
      """
      const probe = document.createElement('span')
      probe.className = 'bg-ground'
      document.body.append(probe)
      const style = id => getComputedStyle(document.getElementById(id))
      return [Math.round(document.getElementById('confirm-edit-subscription').getBoundingClientRect().height),
              style('edit-subscription-heading').fontSize, style('edit-subscription-actions').backgroundColor,
              getComputedStyle(probe).backgroundColor,
              Math.round(document.getElementById('subscription-form').getBoundingClientRect().top -
                document.getElementById('edit-subscription-heading').getBoundingClientRect().bottom)]
      """,
      fn [height, title, band, ground, gap] ->
        assert height == 36
        assert title == "17px"
        assert band == ground
        assert gap >= 20, "a form stands apart from the title"
      end
    )
  end

  # On a phone the answers stand one above the other across the dialog, at a finger's height, the
  # one that confirms on top.
  @sessions [
    [
      capabilities:
        put_in(Wallaby.Chrome.default_capabilities(), [:chromeOptions, :mobileEmulation], %{
          deviceMetrics: %{width: 390, height: 844, pixelRatio: 1}
        })
    ]
  ]
  feature "a dialog's answers stack at a finger's height on a phone", %{session: session} do
    feed = subscribed(session)

    session
    |> open("/feeds/#{feed}")
    |> click(css("#edit-subscription"))
    |> assert_has(css("dialog#edit-subscription-confirm[open]"))
    |> execute_script(
      """
      const box = id => document.getElementById(id).getBoundingClientRect()
      const save = box('confirm-edit-subscription'), cancel = box('cancel-edit-subscription')
      const band = document.getElementById('edit-subscription-actions')
      const inner = band.clientWidth - parseFloat(getComputedStyle(band).paddingLeft) -
        parseFloat(getComputedStyle(band).paddingRight)
      return [Math.round(save.height), Math.round(save.width) == Math.round(inner),
              save.bottom <= cancel.top, box('unsubscribe').top >= cancel.bottom]
      """,
      fn [height, across, save_first, leave_last] ->
        assert height == 44
        assert across, "the answer spans the dialog"
        assert save_first, "saving stands above cancelling"
        assert leave_last, "leaving stands at the foot"
      end
    )
  end

  # From lg the sources may run long. They scroll, while the wordmark above and the offer of the
  # source below stay where they are. Only a window too short for those two scrolls the whole
  # column. The heading over the sources leads to managing them, so the bar of links is the phone's.
  feature "the sidebar scrolls between a standing wordmark and its foot", %{session: session} do
    signed_up(session, "ada")

    session
    |> resize_window(1440, 900)
    |> open("/subscriptions")
    |> execute_script(
      """
      const style = selector => getComputedStyle(document.querySelector(selector))
      return [style('#sidebar').overflowY, style('header:has(#sidebar)').overflowY,
              style('#main-navigation').display]
      """,
      fn [sidebar, header, link] ->
        assert sidebar == "auto"
        assert header == "auto"
        assert link == "none"
      end
    )
  end

  # The active count is tinted, not moved: its digits end where every other count's do, as far
  # from the right edge as the name starts from the left.
  feature "an active count lines up with the others", %{session: session} do
    account = signed_up(session, "ada")
    {:ok, preview} = Parser.parse(FeedFixtures.podcast(), "https://example.org/rss")
    {:ok, _} = Library.subscribe(account, preview)

    session
    |> resize_window(1440, 900)
    |> open("/all")
    |> assert_has(css("#view-all[aria-current=page] #view-all-count"))
    |> execute_script(
      """
      const right = id => {
        const range = document.createRange()
        range.selectNodeContents(document.getElementById(id))
        return Math.round(range.getBoundingClientRect().right)
      }
      const link = document.getElementById('view-inbox').getBoundingClientRect()
      // The row starts with the view's icon.
      const start = document.querySelector('#view-inbox > span').firstElementChild
      return [right('view-all-count'), right('view-inbox-count'),
              Math.round(start.getBoundingClientRect().left - link.left),
              Math.round(link.right) - right('view-inbox-count')]
      """,
      fn [active, inactive, left_inset, right_inset] ->
        assert active == inactive
        assert left_inset == right_inset, "the digits sit as far from the edge as the icon"
      end
    )
  end

  defp subscribed(session) do
    account = signed_up(session, "ada")
    {:ok, preview} = Parser.parse(FeedFixtures.podcast(), "https://example.org/rss")
    {:ok, _} = Library.subscribe(account, preview)
    hd(Library.entries(account)).feed_id
  end

  defp wordmark do
    """
    const name = document.querySelector('#project-name')
    return [getComputedStyle(name).color,
            getComputedStyle(name.querySelector('[aria-hidden]')).backgroundColor,
            getComputedStyle(document.body).color]
    """
  end

  defp system_scheme(session, value) do
    {:ok, _} =
      Wallaby.HTTPClient.request(:post, "#{session.url}/chromium/send_command_and_get_result", %{
        cmd: "Emulation.setEmulatedMedia",
        params: %{features: [%{name: "prefers-color-scheme", value: value}]}
      })

    session
  end
end
