# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.FeatureWaitsTest do
  @moduledoc """
  Forbids Wallaby's `refute_has/2` in features.

  `refute_has/2` retries until the element is present. When it is absent, the assertion passes
  only after the full `max_wait_time`. When it is still present, for example before a click's
  LiveView reply arrives, the assertion fails at once. `SikioWeb.FeatureCase.gone/2` retries until
  the element count is zero.
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
