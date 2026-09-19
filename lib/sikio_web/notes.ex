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
    |> Enum.map_join(&"<p>#{Plug.HTML.html_escape(&1)}</p>")
    |> safe()
  end

  def notes(description, _html) do
    description
    |> without_code()
    |> HtmlSanitizeEx.basic_html()
    |> safe()
  end

  defp safe(""), do: nil

  # Marking markup safe is this module's whole purpose, and the scanner cannot see that both
  # callers escaped or sanitized the value one line earlier. Only they may call this, and the
  # tests beside them are what guards it.
  # sobelow_skip ["XSS.Raw"]
  defp safe(html), do: Phoenix.HTML.raw(html)

  defp without_code(description) do
    case Floki.parse_fragment(description) do
      {:ok, tree} -> tree |> Floki.filter_out("script, style") |> Floki.raw_html()
      _ -> description
    end
  end
end
