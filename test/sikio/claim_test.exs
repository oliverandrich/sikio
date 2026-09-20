# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ClaimTest do
  @moduledoc """
  The one claim mode this application supports, asked where an instance starts.

  Ithibati offers an open claim as well. Sikio does not: an instance answers on the network before
  anybody has claimed it, so leaving that claim open is a race against strangers. The library
  option therefore has one permitted value here, and an instance configured otherwise must say so
  and stop rather than serve a claim anybody can take.
  """
  use ExUnit.Case, async: false

  alias Sikio.Claim
  alias Sikio.TestConfig

  # The posture this ships with, asked of the configuration every environment actually loads.
  # A posture that only holds in production is a posture nothing runs against.
  test "the mode this application ships with is the one it supports" do
    assert Claim.verify!() == :ok
  end

  test "an open claim is refused, and the message names the key to change" do
    TestConfig.put_env(:ithibati, :initial_claim, :open)

    assert_raise RuntimeError, ~r/initial_claim/, fn -> Claim.verify!() end
  end

  # The library refuses a value it cannot read at all, which says the same thing louder.
  test "a mode the library cannot read is refused too" do
    TestConfig.put_env(:ithibati, :initial_claim, :operator_codes)

    assert_raise ArgumentError, ~r/initial_claim/, fn -> Claim.verify!() end
  end
end
