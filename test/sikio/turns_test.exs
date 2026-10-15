# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.TurnsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Sikio.Turns

  # Each runner reports when it starts and holds its slot until the test releases it.
  defp runner(turns, test) do
    Task.async(fn ->
      Turns.run(turns, fn ->
        send(test, {:running, self()})
        receive do: (:done -> :ok)
      end)
    end)
  end

  test "lets as many runs through as it has turns and queues the rest" do
    turns = :"turns-#{System.unique_integer([:positive])}"
    start_supervised!({Turns, name: turns, limit: 2})
    tasks = for _ <- 1..4, do: runner(turns, self())

    assert_receive {:running, first}
    assert_receive {:running, _second}
    refute_receive {:running, _}, 100

    send(first, :done)
    assert_receive {:running, third}
    refute_receive {:running, _}, 100

    send(third, :done)
    assert_receive {:running, _fourth}
    for task <- tasks, do: send(task.pid, :done)
    Task.await_many(tasks)
  end

  # A run that crashes returns its turn, so the queue does not stall.
  test "returns the turn of a run that crashes" do
    turns = :"turns-#{System.unique_integer([:positive])}"
    start_supervised!({Turns, name: turns, limit: 1})

    crashed = Task.async(fn -> catch_exit(Turns.run(turns, fn -> exit(:boom) end)) end)
    assert Task.await(crashed) == :boom
    assert Turns.run(turns, fn -> :ran end) == :ran
  end
end
