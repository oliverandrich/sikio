# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.SharedIdentifiersTest do
  @moduledoc """
  What keeps the suite from deadlocking against itself.

  Almost every test file is `async: true`, each in its own sandbox transaction. Two transactions
  that take the same two rows in opposite order deadlock, and Postgres kills one of them. The
  only thing standing between the suite and that is whether two of them ever write the same row.

  The deadlock itself cannot be pinned by a test: it depends on how two transactions interleave,
  and it happens in Postgres rather than in anything here. What can be pinned is the property
  that removes the hazard, which is this.

  The property is asked directly rather than through a list of names somebody has to remember
  to extend. A list only ever covers what its author had in mind.
  """
  use ExUnit.Case, async: true

  @fixtures "test/support/feed_fixtures.ex"

  # A name a test writes, and an address it turns into a feed row.
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

  # Both halves of the hazard: a sandbox to write in, and another test running at the same
  # moment. ExUnit runs the synchronous ones after every async one has finished, so a feature
  # test cannot be the other half. One made async starts being covered.
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

  # What the fixtures spell is shared on purpose: it is the document every test reads, not a row
  # any of them invents. Only what a test makes up for itself can collide.
  defp fixture_content do
    source = File.read!(@fixtures)

    @patterns
    |> Enum.flat_map(&Regex.scan(&1, source, capture: :all_but_first))
    |> List.flatten()
  end
end
