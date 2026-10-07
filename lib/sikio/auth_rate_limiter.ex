# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.AuthRateLimiter do
  @moduledoc """
  Per-node fixed-window counters with bounded capacity, and the budget of each group.

  Use an edge rate limit across multiple nodes. The budgets live here, not in the plug that uses
  most of them. Callers outside the web layer can then read them without depending on it.
  """
  use GenServer

  # `invite` uses a one-day window. The threat is a compromised account sending mail through the
  # operator's credentials at a steady rate, not a burst. Twenty a day exceeds legitimate use.
  @defaults [recovery: {10, 60}, ceremony: {120, 60}, setup: {10, 60}, invite: {20, 86_400}]

  @doc """
  Returns the `{limit, seconds}` budget for one group of auth requests.

  Every caller reads budgets through this function, so every group in `@defaults` is available.
  The fallback applies per group. Configuring one budget replaces the whole list, and a missing
  group must not make its requests fail.
  """
  def budget(group) do
    :sikio
    |> Application.get_env(:auth_rate_limits, [])
    |> Keyword.get(group, Keyword.fetch!(@defaults, group))
  end

  def start_link(opts),
    do:
      GenServer.start_link(Sikio.AuthRateLimiter, Keyword.get(opts, :capacity, 10_000),
        name: Keyword.get(opts, :name, Sikio.AuthRateLimiter)
      )

  def check(key, limit, seconds, server \\ Sikio.AuthRateLimiter),
    do: GenServer.call(server, {:check, key, limit, seconds})

  @impl true
  def init(capacity), do: {:ok, %{capacity: capacity, groups: %{}}}

  # Each group has its own map and capacity, so a flood in one group cannot block another.
  # A full group refuses a new key until its earliest entry expires.
  # The error returns that wait, because the window may be a day.
  @impl true
  def handle_call({:check, {group, _id} = key, limit, seconds}, _from, state) do
    now = System.monotonic_time(:second)
    keys = Map.get(state.groups, group, %{})

    {keys, earliest} =
      if map_size(keys) >= state.capacity, do: expire(keys, now), else: {keys, nil}

    {reply, keys} =
      case Map.get(keys, key) do
        {count, until} when until > now and count >= limit ->
          {{:error, until - now}, keys}

        {count, until} when until > now ->
          {:ok, Map.put(keys, key, {count + 1, until})}

        _ when map_size(keys) < state.capacity or is_map_key(keys, key) ->
          {:ok, Map.put(keys, key, {1, now + seconds})}

        _ ->
          {{:error, earliest - now}, keys}
      end

    {:reply, reply, %{state | groups: Map.put(state.groups, group, keys)}}
  end

  # Removes expired entries and returns the earliest remaining expiry.
  defp expire(keys, now) do
    Enum.reduce(keys, {%{}, nil}, fn
      {_key, {_count, until}}, acc when until <= now ->
        acc

      {key, {_count, until} = entry}, {kept, earliest} ->
        {Map.put(kept, key, entry), min(until, earliest || until)}
    end)
  end
end
