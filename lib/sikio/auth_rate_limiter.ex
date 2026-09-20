# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.AuthRateLimiter do
  @moduledoc "Bounded per-node fixed-window counters. Use an edge limit across multiple nodes."
  use GenServer

  def start_link(opts),
    do:
      GenServer.start_link(Sikio.AuthRateLimiter, %{},
        name: Keyword.get(opts, :name, Sikio.AuthRateLimiter)
      )

  def check(key, limit, seconds, server \\ Sikio.AuthRateLimiter),
    do: GenServer.call(server, {:check, key, limit, seconds})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:check, key, limit, seconds}, _from, state) do
    now = System.monotonic_time(:second)

    state =
      if map_size(state) >= 10_000,
        do: Map.reject(state, fn {_key, {_count, until}} -> until <= now end),
        else: state

    case Map.get(state, key) do
      {count, until} when until > now and count >= limit ->
        {:reply, {:error, until - now}, state}

      {count, until} when until > now ->
        {:reply, :ok, Map.put(state, key, {count + 1, until})}

      _ ->
        if map_size(state) < 10_000 or Map.has_key?(state, key) do
          {:reply, :ok, Map.put(state, key, {1, now + seconds})}
        else
          {:reply, {:error, seconds}, state}
        end
    end
  end
end
