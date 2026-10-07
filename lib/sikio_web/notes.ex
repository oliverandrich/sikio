# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Notes do
  @moduledoc """
  Sanitizes show notes for rendering.

  Notes are stored unfiltered, as the feed delivered them. Sanitizing happens here at render time.
  A changed filter therefore also applies to entries imported earlier.
  """

  @doc """
  Returns the notes as safe HTML, or nil when nothing remains.

  `format` is `:html` or `:text`. YouTube descriptions and `itunes:summary` are text.
  Parsing text as HTML drops everything after a stray `<`.
  Escaping HTML as text displays the tags.

  HTML goes through `HtmlSanitizeEx.basic_html/1`.
  It keeps paragraphs, lists, emphasis and links.
  It drops all other elements, event attributes and `javascript:` URLs.
  This matters because the CSP `script-src` allows `'unsafe-inline'`.
  `script` and `style` elements are removed with their contents first.
  The sanitizer alone drops those tags but keeps their text.

  Text is HTML-escaped. Each non-blank line becomes a paragraph, which keeps chapter lists intact.
  URLs in it become links.

  After sanitizing, `img` elements with an `https` `src` are proxied through `SikioWeb.Pictures`.
  Other `img` elements are dropped, because the CSP `img-src` allows only `'self'` and `data:`.
  Links get `target="_blank"`, so following one does not navigate away from the player dock.

  The result is wrapped with `Phoenix.HTML.raw/1`, so templates render it unescaped.
  """
  def notes(description, format \\ :html)

  def notes(nil, _format), do: nil

  def notes(description, :text) do
    description
    |> String.split(~r/\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] ->
        nil

      lines ->
        lines |> Enum.map_join(&"<p>#{&1 |> Plug.HTML.html_escape() |> linked()}</p>") |> marked()
    end
  end

  def notes(description, _html) do
    description
    |> without_code()
    |> HtmlSanitizeEx.basic_html()
    |> outward()
  end

  # Matches an http(s) URL in escaped text, up to whitespace or an escaped quote or angle bracket.
  # Other schemes such as `javascript:` never match.
  @address ~r{https?://(?:(?!&quot;|&#39;|&lt;|&gt;)[^\s<>"])+}u

  # Turns bare URLs in plain text into links that open in a new tab, as in HTML notes.
  # The input is already escaped, so `&` appears as `&amp;` in both `href` and link text.
  defp linked(escaped) do
    Regex.replace(@address, escaped, fn found ->
      {address, after_it} = trailing(found, "")

      ~s(<a href="#{address}" target="_blank" rel="noopener noreferrer">#{address}</a>) <>
        after_it
    end)
  end

  # Moves trailing punctuation out of the URL. A `)` stays when the URL contains a `(`,
  # as Wikipedia URLs do.
  defp trailing(address, after_it) do
    last = String.last(address)

    cond do
      # The text is escaped, so a trailing `;` may end an entity such as `&amp;`. It stays.
      Regex.match?(~r/&[a-z0-9#]+;$/i, address) ->
        {address, after_it}

      last in [".", ",", ";", ":", "!", "?", "]"] ->
        trailing(String.slice(address, 0..-2//1), last <> after_it)

      last == ")" and not String.contains?(address, "(") ->
        trailing(String.slice(address, 0..-2//1), last <> after_it)

      true ->
        {address, after_it}
    end
  end

  # Sobelow flags `raw/1`. Both callers escape or sanitize the value immediately before.
  # Only those callers use this function, and their tests cover the escaping.
  # sobelow_skip ["XSS.Raw"]
  defp marked(html), do: Phoenix.HTML.raw(html)

  # Returns nil when the filtered notes contain neither text nor an `img`.
  defp outward(html) do
    with {:ok, tree} <- Floki.parse_fragment(html),
         tree = Floki.traverse_and_update(tree, &outward_node/1),
         false <- String.trim(Floki.text(tree)) == "" and Floki.find(tree, "img") == [] do
      tree |> Floki.raw_html() |> marked()
    else
      _ -> nil
    end
  end

  defp outward_node({"img", attrs, _children}) do
    case List.keyfind(attrs, "src", 0) do
      {"src", "https://" <> _ = src} ->
        alt = attrs |> List.keyfind("alt", 0, {"alt", ""}) |> elem(1)

        {"img",
         [
           {"src", SikioWeb.Pictures.path([src], "/images/nothing.svg")},
           {"alt", alt},
           {"loading", "lazy"}
         ], []}

      _ ->
        nil
    end
  end

  defp outward_node({"a", attrs, children}) do
    attrs = Enum.reject(attrs, fn {name, _value} -> name in ["target", "rel"] end)
    {"a", attrs ++ [{"target", "_blank"}, {"rel", "noopener noreferrer"}], children}
  end

  defp outward_node(node), do: node

  defp without_code(description) do
    case Floki.parse_fragment(description) do
      {:ok, tree} -> tree |> Floki.filter_out("script, style") |> Floki.raw_html()
      _ -> description
    end
  end
end
