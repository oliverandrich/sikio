# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.SearchRankTest do
  use ExUnit.Case, async: true

  alias Sikio.Feeds.SearchRank

  test "an exact title beats a prefix, a word, a substring and a fuzzy match" do
    scores =
      Enum.map(
        [
          "MAITHINK X",
          "Maithink X – die Show",
          "Das Beste aus Maithink X",
          "Maithink Xtra",
          "Maithunk"
        ],
        &SearchRank.score("maithink x", &1)
      )

    assert scores == Enum.sort(scores, :desc)
    assert scores == Enum.uniq(scores)
  end

  test "case, diacritics and punctuation do not matter" do
    assert SearchRank.score("Maithink X", "maithink-x") == 1.0
    assert SearchRank.score("tagesschau", "Tagesschäu") == 1.0
  end

  test "a misspelt term still finds its title before unrelated ones" do
    assert SearchRank.score("Maythink", "MAITHINK X") >
             SearchRank.score("Maythink", "The Matthew Dark Show")

    assert SearchRank.score("Maythink", "The Matthew Dark Show") >
             SearchRank.score("Maythink", "Bible Race")
  end

  test "the origin's name counts below the title" do
    by_origin = SearchRank.score("maithink x", "Warum Klimaschutz wirkt", "MAITHINK X")

    assert by_origin > SearchRank.score("maithink x", "Warum Klimaschutz wirkt")
    assert by_origin < SearchRank.score("maithink x", "MAITHINK X")
    # An exact origin stays below a title that starts with the term.
    assert by_origin < SearchRank.score("maithink x", "Maithink X – die Show")
  end

  # Scraped titles can carry broken bytes. They score, they do not crash the page.
  test "a title with invalid UTF-8 still scores" do
    assert SearchRank.score("maithink", "Maithink " <> <<0xFF>>) > 0.0
  end

  test "an empty term or title scores nothing" do
    assert SearchRank.score("", "MAITHINK X") == 0.0
    assert SearchRank.score("--", "MAITHINK X") == 0.0
    assert SearchRank.score("maithink", "", nil) == 0.0
  end
end
