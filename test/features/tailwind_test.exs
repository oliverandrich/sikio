# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.TailwindTest do
  use SikioWeb.FeatureCase

  alias Sikio.FeedFixtures
  alias Sikio.Feeds.Parser
  alias Sikio.Library

  # Page backgrounds, Tailwind's neutral-50 and neutral-950, read as computed style.
  # A class name does not show the value the stylesheet resolves to.
  # A Tailwind palette change alters these values and fails this test on purpose.
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
    |> gone(css("[data-phx-theme]"))
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

  # Durations, dates and counts use the mono font. The test checks the runtime element only.
  # Browsers load a font face only when used. A missing face falls back without an error.
  feature "metadata is set in IBM Plex Mono, and the face is loaded", %{session: session} do
    account = signed_in(session, "ada")

    {:ok, preview} =
      Parser.parse(FeedFixtures.podcast(), "https://example.org/rss")

    {:ok, _} = Library.subscribe(account, preview)
    [entry] = Library.entries(account)

    session
    |> open("/all")
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

  # On a phone the confirm button spans the action row at 44 px height.
  # The buttons stack in the order confirm, cancel, unsubscribe.
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

  # From lg the source list can be long. It scrolls inside `#sidebar`.
  # The wordmark above and the add-source link below stay outside the scrolling list.
  # The whole header scrolls only in a window too short for those two.
  # A pencil icon beside the sources links to their management, so the link bar is phone-only.
  # The test checks computed `overflowY` and `display`, not actual scrolling.
  feature "the lg sidebar may scroll and hides the bar of links", %{session: session} do
    signed_in(session, "ada")

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

  # The dark background, oklch(0.145 0 0), in sRGB.
  @dark_page {10, 10, 10}

  # A source without a fetchable image shows an SVG for its kind instead.
  # An image does not inherit page colours, so the SVG has its own dark scheme.
  # The mark needs 3:1 contrast against its background, the WCAG minimum for graphics.
  # The SVG background is composited over the page's dark background first.
  feature "a source's fallback picture stands out in the dark", %{session: session} do
    for path <- ["/images/kind-audio.svg", "/images/kind-video.svg"] do
      session
      |> system_scheme("dark")
      |> visit(path)
      |> execute_script(
        """
        const ground = getComputedStyle(document.querySelector('rect'));
        const mark = getComputedStyle(document.querySelector('rect + *'));
        const [paint, opacity] = mark.fill !== 'none'
          ? [mark.fill, mark.fillOpacity] : [mark.stroke, mark.strokeOpacity];
        return [ground.fill, ground.fillOpacity, paint, opacity];
        """,
        fn [ground, ground_opacity, mark, mark_opacity] ->
          ground = over(rgb(ground), ground_opacity, @dark_page)
          assert contrast(over(rgb(mark), mark_opacity, ground), ground) >= 3, path
        end
      )
    end
  end

  defp rgb(color) do
    [r, g, b] = Regex.scan(~r/\d+/, color) |> Enum.take(3) |> Enum.map(&String.to_integer(hd(&1)))
    {r, g, b}
  end

  defp over({r, g, b}, opacity, {br, bg, bb}) do
    {a, ""} = Float.parse(opacity)
    {r * a + br * (1 - a), g * a + bg * (1 - a), b * a + bb * (1 - a)}
  end

  # WCAG 2 relative luminance and contrast ratio.
  defp contrast(a, b) do
    [high, low] = Enum.sort([luminance(a), luminance(b)], :desc)
    (high + 0.05) / (low + 0.05)
  end

  defp luminance({r, g, b}) do
    [r, g, b] =
      for c <- [r, g, b] do
        c = c / 255
        if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  defp subscribed(session) do
    account = signed_in(session, "ada")
    {:ok, preview} = Parser.parse(FeedFixtures.podcast(), "https://example.org/rss")
    {:ok, _} = Library.subscribe(account, preview)
    hd(Library.entries(account)).feed_id
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
