# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.FeatureWaitsTest do
  @moduledoc """
  What keeps the browser features from waiting for nothing and failing on a race.

  Wallaby's `refute_has/2` retries until the element appears. On a page without it, it waits the
  whole `max_wait_time` before it passes. On a page that still shows it, because the reply to a
  click has not arrived, it fails at once. `SikioWeb.FeatureCase.gone/2` waits for absence instead.
  """
  use ExUnit.Case, async: true

  test "no feature asks refute_has" do
    files = Path.wildcard("test/features/**/*.exs")
    assert files != [], "this found no features to look at"

    found =
      for path <- files,
          {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim_leading(line), "#"),
          line =~ ~r/\brefute_has\b/,
          do: "  #{path}:#{number}"

    assert found == [],
           "Use gone/2 from SikioWeb.FeatureCase instead:\n\n#{Enum.join(found, "\n")}"
  end
end
