# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.TrustedProxiesTest do
  @moduledoc """
  What `config/runtime.exs` makes of `TRUSTED_PROXIES`, run against the file itself.

  Nothing else executes that block. A release reads it once at startup, so a value this parser
  mishandles is first seen as an instance that will not boot, or worse, as one that boots and
  trusts nothing it was told to trust.
  """
  use ExUnit.Case, async: false

  # One helper for both variables. The environment differs because the identity block is kept out
  # of tests, where a shell that happens to export it must not decide what the suite runs against.
  defp read(mix_env, variable, value, key) do
    System.put_env(variable, value)
    on_exit(fn -> System.delete_env(variable) end)

    "config/runtime.exs"
    |> Config.Reader.read!(env: mix_env)
    |> get_in([:sikio, key])
  end

  defp configured(value), do: read(:test, "TRUSTED_PROXIES", value, :trusted_proxies)

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
  defp identity(value), do: read(:dev, "ACCOUNT_IDENTITY", value, :account_identity)

  test "an account is named or addressed, and says so either way" do
    assert identity("email") == :email
    assert identity("username") == :username
  end

  # The same promise `TRUSTED_PROXIES` keeps. Taking only the exact word and dropping the rest in
  # silence would boot an instance naming its accounts while its operator configured addresses.
  test "and anything else stops the boot rather than being dropped quietly" do
    assert_raise RuntimeError, ~r/Email/, fn -> identity("Email") end
  end

  test "something that is not an address stops the boot and says which one" do
    assert_raise RuntimeError, ~r/proxy\.example\.com/, fn ->
      configured("10.0.0.2,proxy.example.com")
    end
  end
end
