# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.SharedIdentifiersTest do
  @moduledoc """
  Prevents deadlocks between async tests.

  Most test files are `async: true`, each in its own sandbox transaction. Two transactions that
  lock the same two rows in opposite order deadlock, and Postgres aborts one of them. This
  requires two concurrent tests to write the same row.

  A test cannot reproduce the deadlock reliably, because it depends on transaction interleaving.
  This test checks the precondition instead: no two async files share a username or feed URL
  literal. It scans the source files rather than a hand-maintained list of names.
  """
  use ExUnit.Case, async: true

  @fixtures "test/support/feed_fixtures.ex"

  # Username literals and feed URL literals.
  @patterns [~r/username: "([^"]+)"/, ~r/"(https:\/\/[^"]+)"/]

  test "no two concurrent tests write a row under the same name" do
    files = concurrent_files()
    assert files != [], "this found no test files to look at, which is not the same as no risk"

    shared =
      files
      |> Enum.flat_map(fn path -> Enum.map(literals(path), &{&1, path}) end)
      |> Enum.reject(fn {literal, _path} -> literal in fixture_content() end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.filter(fn {_literal, paths} -> length(Enum.uniq(paths)) > 1 end)
      |> Enum.map(fn {literal, paths} -> "  #{literal}\n    #{Enum.join(paths, "\n    ")}" end)

    assert shared == [],
           """
           These name a row that another test may write at the same moment:

           #{Enum.join(shared, "\n")}

           Use Sikio.DataCase.unique_username/1, or one of the address generators in
           Sikio.FeedFixtures: feed_url/1, youtube_feed_url/0, peertube_feed_url/0.
           """
  end

  # Selects async files that use a sandbox case template.
  # ExUnit runs synchronous tests after all async tests, so they cannot collide.
  # A file that becomes async is included automatically.
  defp concurrent_files do
    for path <- Path.wildcard("test/**/*.ex{,s}"),
        path != @fixtures,
        source = File.read!(path),
        source =~ "async: true",
        source =~ "use Sikio.DataCase" or source =~ "use SikioWeb.ConnCase" or
          source =~ "use SikioWeb.FeatureCase",
        do: path
  end

  defp literals(path) do
    source = File.read!(path)

    @patterns
    |> Enum.flat_map(&Regex.scan(&1, source, capture: :all_but_first))
    |> List.flatten()
    |> Enum.uniq()
  end

  # Literals from the shared fixtures are excluded. Every test reads them; only test-local
  # literals can collide.
  defp fixture_content do
    source = File.read!(@fixtures)

    @patterns
    |> Enum.flat_map(&Regex.scan(&1, source, capture: :all_but_first))
    |> List.flatten()
  end
end
