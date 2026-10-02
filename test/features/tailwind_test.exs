# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.TailwindTest do
  use SikioWeb.FeatureCase

  alias Sikio.FeedFixtures
  alias Sikio.Feeds.Parser
  alias Sikio.Library

  # Sikio's own grounds, Tailwind's slate-100 and slate-950, read from the browser rather than from
  # the markup: a class name proves nothing about what a stylesheet finally resolves to. A palette
  # retune in Tailwind changes these values, which is worth noticing.
  @ground "oklch(0.968 0.007 247.896)"
  @dark_ground "oklch(0.129 0.042 264.695)"

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
      return [color(probe), color(document.getElementById('subscriptions-link')),
              color(document.getElementById('invitations-link'))]
      """,
      fn [accent, active, inactive] ->
        assert active == accent
        refute inactive == accent
      end
    )
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
