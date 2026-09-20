# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.TailwindTest do
  use SikioWeb.FeatureCase

  # Sikio's own surface, warm rather than white, and read from the browser rather than from the
  # markup: a class name proves nothing about what a stylesheet finally resolves to.
  @paper "rgb(247, 246, 242)"

  feature "styles follow system changes and ignore an old stored theme", %{session: session} do
    session
    |> system_scheme("light")
    |> open("/")
    |> execute_script("localStorage.setItem('phx:theme', 'dark')")
    |> open("/")
    |> execute_script("return getComputedStyle(document.body).backgroundColor", fn color ->
      assert color == @paper
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
      refute color in [@paper, "rgb(255, 255, 255)", "rgba(0, 0, 0, 0)"]
    end)
    |> system_scheme("light")
    |> execute_script("return getComputedStyle(document.body).backgroundColor", fn color ->
      assert color == @paper
    end)
  end

  # The exact value is Tailwind's to choose and it may retune a palette, so what is pinned here is
  # what the design actually promises: the wordmark is an accent rather than body text, and it is a
  # different accent once the page turns dark.
  feature "the wordmark carries an accent colour that adapts to the scheme", %{session: session} do
    session
    |> system_scheme("light")
    |> open("/")
    |> execute_script(wordmark_and_text(), fn [wordmark, text] ->
      refute wordmark == text
    end)
    |> execute_script(wordmark(), fn light ->
      session
      |> system_scheme("dark")
      |> execute_script(wordmark(), fn dark -> refute dark == light end)
    end)
  end

  defp wordmark, do: "return getComputedStyle(document.querySelector('#project-name')).color"

  defp wordmark_and_text do
    """
    return [getComputedStyle(document.querySelector('#project-name')).color,
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
