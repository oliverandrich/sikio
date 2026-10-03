# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.SearchText do
  @moduledoc """
  What the library's search reads: an entry's title, excerpt and notes as plain lowercase text.

  It is written on import because neither database can do all of it alike. Markup comes out, so
  a tag is never a match, and the space it leaves is one space, so a phrase across it still is.
  Case is folded here, in Unicode, because SQLite folds only ASCII.
  """

  @doc "The searchable text of an entry's fields, or nil when it has none."
  def of(entry) do
    [entry[:title], entry[:excerpt], plain(entry[:description], entry[:description_format])]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp plain(nil, _format), do: nil
  defp plain(notes, format) when format in [:text, "text"], do: notes

  defp plain(notes, _html) do
    case Floki.parse_fragment(notes) do
      {:ok, tree} -> Floki.text(tree, sep: " ")
      _ -> nil
    end
  end
end
