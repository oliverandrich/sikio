# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Turns do
  @moduledoc """
  Lets at most `limit` callers run at once and queues the rest in arrival order.

  The work runs in the caller's process; the server only grants turns. A caller that exits,
  normally or not, returns its turn. Start one per limited resource with `:name` and `:limit`.
  """
  use GenServer

  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :limit), name: name)
  end

  @doc "Runs `fun` once a turn of `turns` is free and returns its result."
  def run(turns, fun) do
    :ok = GenServer.call(turns, :acquire, :infinity)

    try do
      fun.()
    after
      GenServer.cast(turns, {:release, self()})
    end
  end

  @impl true
  def init(limit), do: {:ok, %{limit: limit, active: %{}, waiting: :queue.new()}}

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, state) do
    if map_size(state.active) < state.limit,
      do: {:reply, :ok, grant(state, pid)},
      else: {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
  end

  @impl true
  def handle_cast({:release, pid}, state), do: {:noreply, release(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, release(state, pid)}

  defp grant(state, pid), do: put_in(state.active[pid], Process.monitor(pid))

  defp release(state, pid) do
    case Map.pop(state.active, pid) do
      {nil, _active} ->
        state

      {ref, active} ->
        Process.demonitor(ref, [:flush])
        next(%{state | active: active})
    end
  end

  # A waiter that died meanwhile gets the turn and returns it at once through its monitor.
  defp next(state) do
    case :queue.out(state.waiting) do
      {{:value, {pid, _tag} = from}, waiting} ->
        GenServer.reply(from, :ok)
        grant(%{state | waiting: waiting}, pid)

      {:empty, _waiting} ->
        state
    end
  end
end
