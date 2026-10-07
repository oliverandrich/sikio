# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Claim do
  @moduledoc """
  Sikio requires an operator's code for the first account and supports no other claim mode.

  Ithibati also offers `initial_claim: :open`. It suits an instance unreachable before its owner
  registers. Sikio listens on the network from start, so an open claim goes to the first visitor.

  `:operator_code` is the only permitted value. `Sikio.Application` calls `verify!/0` at start,
  so any other value stops the boot.
  """
  alias Ithibati.Config

  @supported :operator_code

  @doc "Returns `:ok`, or raises naming the key to change and its required value."
  def verify! do
    case Config.initial_claim_mode() do
      @supported ->
        :ok

      other ->
        raise """
        Sikio protects the first account with an operator's code and supports nothing else.

        config :ithibati, initial_claim: #{inspect(other)}

        Set it to #{inspect(@supported)}, then issue a code: bin/setup-code in an
        unpacked release, mise run setup-code in development.
        """
    end
  end
end
