# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ClaimTest do
  @moduledoc """
  Tests `Sikio.Claim.verify!/0`, which permits only `initial_claim: :operator_code`.

  Ithibati also offers an open claim. Sikio is reachable on the network before the first account
  exists, so an open claim goes to the first visitor. Any other value raises.
  """
  use ExUnit.Case, async: false

  alias Sikio.Claim
  alias Sikio.TestConfig

  # Checks the value from `config/config.exs`, which every environment loads.
  test "the mode this application ships with is the one it supports" do
    assert Claim.verify!() == :ok
  end

  test "an open claim is refused, and the message names the key to change" do
    TestConfig.put_env(:ithibati, :initial_claim, :open)

    assert_raise RuntimeError, ~r/initial_claim/, fn -> Claim.verify!() end
  end

  # Ithibati raises `ArgumentError` for an unknown mode.
  test "a mode the library cannot read is refused too" do
    TestConfig.put_env(:ithibati, :initial_claim, :operator_codes)

    assert_raise ArgumentError, ~r/initial_claim/, fn -> Claim.verify!() end
  end
end
