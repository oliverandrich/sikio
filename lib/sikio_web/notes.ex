# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Notes do
  @moduledoc """
  A publisher's show notes, reduced to what a reader needs.

  Its own module because it is a boundary rather than a convenience. The notes arrive from
  whoever publishes the feed and are stored as they came, so the filtering happens here on the
  way out and a better filter tomorrow applies to what was imported yesterday.
  """

  @doc """
  The notes as markup a template may render, read according to what the publisher wrote.

  A podcast writes markup and YouTube writes plain text. Reading text as markup loses everything
  after a stray `<`, and reading markup as text shows the reader the tags, so the entry says
  which it holds and this decides accordingly.

  Markup goes through `basic_html`, which keeps paragraphs, lists, emphasis and links and drops
  everything else, including event attributes and `javascript:` targets. That matters because
  `script-src` allows inline scripts, so a handler that survived would run. Script and style
  elements lose their contents first: the sanitizer drops those tags but keeps the text between
  them, and a reader has no use for somebody's stylesheet.

  Text is escaped and its lines become paragraphs, because a chapter list is a list of lines.

  After sanitizing, a picture with an `https` address is served through Sikio's own host and any
  other picture is dropped, because the content security policy refuses the publisher's. A link
  opens in a new tab: following it in place would leave the page and the dock playing in it.

  The answer is marked safe, because a template escapes a plain string and would show the reader
  the tags instead of the notes. Nothing warns about that, so the return type carries it.
  """
  def notes(description, format \\ :html)

  def notes(nil, _format), do: nil

  def notes(description, :text) do
    description
    |> String.split(~r/\R/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> nil
      lines -> lines |> Enum.map_join(&"<p>#{Plug.HTML.html_escape(&1)}</p>") |> marked()
    end
  end

  def notes(description, _html) do
    description
    |> without_code()
    |> HtmlSanitizeEx.basic_html()
    |> outward()
  end

  # Marking markup safe is this module's whole purpose, and the scanner cannot see that both
  # callers escaped or sanitized the value one line earlier. Only they may call this, and the
  # tests beside them are what guards it.
  # sobelow_skip ["XSS.Raw"]
  defp marked(html), do: Phoenix.HTML.raw(html)

  # Notes that hold neither text nor a picture once filtered are no notes.
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
