# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Pictures.Pages do
  @moduledoc """
  Lets at most four web pages be read for their pictures at once, across all requests.

  A list of new Mediathek programmes asks one broadcaster for many pages. The limit keeps that a
  trickle. The page is read in the caller's process; this server only grants turns. A caller
  that exits returns its turn.
  """
  use GenServer

  @limit 4

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Runs `fun` once a turn is free and returns its result."
  def run(fun) do
    :ok = GenServer.call(__MODULE__, :acquire, :infinity)

    try do
      fun.()
    after
      GenServer.cast(__MODULE__, {:release, self()})
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{active: %{}, waiting: :queue.new()}}

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, state) do
    if map_size(state.active) < @limit,
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
