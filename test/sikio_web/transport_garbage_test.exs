# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.TransportGarbageTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias SikioWeb.TransportGarbage

  defp socket(transport_pid),
    do: %Socket{
      transport_pid: transport_pid,
      private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}
    }

  # The join reply leaves the transport process with a heap it never collects while idle.
  # The view asks it to collect once the reply is out.
  test "a connected view asks its transport to collect garbage after the join reply" do
    socket = TransportGarbage.schedule(socket(self()))
    assert_received {TransportGarbage, :collect}

    assert {:halt, _socket} = TransportGarbage.collect({TransportGarbage, :collect}, socket)
    assert_received :garbage_collect
  end

  test "the static render has no transport to ask" do
    TransportGarbage.schedule(socket(nil))
    refute_received {TransportGarbage, :collect}
  end

  test "other messages pass through" do
    assert {:cont, _} = TransportGarbage.collect(:something_else, socket(self()))
  end
end
