# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.SearchText do
  @moduledoc """
  Builds the text library search matches: an entry's title, excerpt and notes, lowercased.

  It is computed on import, because SQLite and PostgreSQL cannot compute it identically.
  HTML tags are stripped, so tag names never match. Whitespace collapses to one space, so a
  phrase still matches across a removed tag. Case folding uses Unicode here, because SQLite
  folds only ASCII.
  """

  @doc "Returns the searchable text of an entry's fields, or nil when it is empty."
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
