# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LayoutsTest do
  @moduledoc """
  Agreement of the username `pattern` attribute with the server rule.

  A `pattern` that differs from `Ithibati.Schema.Identifier.username_format/0` rejects valid
  names or accepts invalid ones, without any error. These tests pin the derivation.
  """
  use ExUnit.Case, async: true

  alias Ithibati.Schema.Identifier
  alias SikioWeb.Layouts

  # HTML anchors `pattern` implicitly. This builds the anchored regex the browser compiles.
  defp as_browser_sees_it do
    Regex.compile!("\\A(?:" <> Layouts.username_pattern() <> ")\\z")
  end

  test "the pattern the form carries answers exactly what the library answers" do
    for value <- [
          "alice",
          "a",
          "_",
          "0123456789",
          String.duplicate("a", 30),
          String.duplicate("a", 31),
          "alice.smith",
          "alice-smith",
          "alice smith",
          "Alice",
          "\u0430lice",
          "alice@example.com",
          "",
          "alice\n"
        ] do
      assert Regex.match?(as_browser_sees_it(), value) ==
               Regex.match?(Identifier.username_format(), value),
             "the form and the server disagree about #{inspect(value)}"
    end
  end

  # `pattern` is ECMAScript, which has no `\A` or `\z`. A browser ignores a pattern
  # that fails to compile, so validation would stop without an error.
  test "and carries no anchor the browser cannot compile" do
    refute Layouts.username_pattern() =~ ~r/\\[Az]/
  end
end
