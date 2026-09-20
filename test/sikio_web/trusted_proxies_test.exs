# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.TrustedProxiesTest do
  @moduledoc """
  What `config/runtime.exs` makes of `TRUSTED_PROXIES`, run against the file itself.

  Nothing else executes that block. A release reads it once at startup, so a value this parser
  mishandles is first seen as an instance that will not boot, or worse, as one that boots and
  trusts nothing it was told to trust.
  """
  use ExUnit.Case, async: false

  defp configured(value) do
    System.put_env("TRUSTED_PROXIES", value)
    on_exit(fn -> System.delete_env("TRUSTED_PROXIES") end)

    "config/runtime.exs"
    |> Config.Reader.read!(env: :test)
    |> get_in([:sikio, :trusted_proxies])
  end

  test "addresses arrive as addresses, in both families" do
    assert configured("10.0.0.2, fd00::2") == [{10, 0, 0, 2}, {64_768, 0, 0, 0, 0, 0, 0, 2}]
  end

  # How a unit file or an environment file writes a variable it has no value for. An empty string
  # is not a list holding an empty name.
  test "an unset variable leaves the default alone" do
    assert configured("") == nil
  end

  # A stray comma leaves an entry of nothing. Naming it plainly would print an empty space, so
  # the message shows it as the empty string it is.
  test "an entry of nothing says so rather than pointing at a blank" do
    assert_raise RuntimeError, ~r/""/, fn -> configured("10.0.0.2, ,fd00::2") end
  end

  # An operator who typed a hostname gets told on the spot. Dropping it would leave an instance
  # that trusts one fewer proxy than its operator believes, which is a rate limit that quietly
  # counts the wrong thing.
  test "something that is not an address stops the boot and says which one" do
    assert_raise RuntimeError, ~r/proxy\.example\.com/, fn ->
      configured("10.0.0.2,proxy.example.com")
    end
  end
end
