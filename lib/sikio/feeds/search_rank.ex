# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.SearchRank do
  @moduledoc """
  Scores how well a search hit's title matches the search term, from 0.0 to 1.0.

  The search indexes rank by measures that cannot be compared, so the add page orders their
  hits by this score. Case, diacritics and punctuation are ignored. An exact title scores
  1.0, ahead of a title that starts with the term, contains it as words or as a substring.
  Any other title scores below 0.6 by its Jaro distance to the term, so a misspelt term
  still finds its title.
  """

  # A hit found by its podcast's or channel's name ranks below one whose title starts with the term.
  @origin_weight 0.85

  # A fuzzy match ranks below every literal one.
  @fuzzy_weight 0.6

  @doc "Returns the score of a hit's title, or of its origin's name when that matches better."
  def score(term, title, origin \\ nil) do
    term = normalized(term)
    title_score = matched(term, normalized(title))

    case origin do
      nil -> title_score
      origin -> max(title_score, @origin_weight * matched(term, normalized(origin)))
    end
  end

  defp matched("", _text), do: 0.0
  defp matched(_term, ""), do: 0.0
  defp matched(term, term), do: 1.0

  defp matched(term, text) do
    cond do
      String.starts_with?(text, term <> " ") -> 0.9
      String.contains?(" " <> text <> " ", " " <> term <> " ") -> 0.8
      String.contains?(text, term) -> 0.7
      true -> @fuzzy_weight * fuzzy(term, text)
    end
  end

  # The best Jaro distance between the term and any run of as many words in the text.
  defp fuzzy(term, text) do
    size = term |> String.split(" ") |> length()

    case text |> String.split(" ") |> Enum.chunk_every(size, 1, :discard) do
      [] -> String.jaro_distance(term, text)
      runs -> runs |> Enum.map(&String.jaro_distance(term, Enum.join(&1, " "))) |> Enum.max()
    end
  end

  defp normalized(nil), do: ""

  defp normalized(text) do
    text
    |> String.replace_invalid()
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
    |> String.trim()
  end
end
