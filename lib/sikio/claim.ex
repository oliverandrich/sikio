# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Claim do
  @moduledoc """
  Sikio protects the first account with an operator's code, and supports nothing else.

  Ithibati offers `initial_claim: :open` as well, which suits an instance nobody can reach before
  its owner does. Sikio is not that: it answers on the network from the moment it starts, so an
  open claim is a race against whoever finds the host first.

  The library option therefore has one permitted value here. This says so once, and `verify!/0`
  is asked where an instance starts, so a wrong value is a refusal to boot rather than a door
  standing open in production.
  """
  alias Ithibati.Config

  @supported :operator_code

  @doc "Answers `:ok`, or raises naming the key to change and the value it takes."
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
