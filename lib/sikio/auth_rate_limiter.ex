# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.AuthRateLimiter do
  @moduledoc """
  Bounded per-node fixed-window counters, and how much each group gets.

  Use an edge limit across multiple nodes. The budgets live here rather than beside the plug that
  spends most of them, so that a caller outside the web layer can ask how much it may do without
  reaching into it.
  """
  use GenServer

  # `invite` counts a day rather than a minute, and the Ithibati Starter counts ten an hour. The
  # threat is not a burst: it is an account somebody else is holding, spending the operator's mail
  # credentials at a steady drip. Ten an hour is two hundred and forty a day; twenty is already
  # well past what anybody asks for legitimately.
  @defaults [recovery: {10, 60}, ceremony: {120, 60}, setup: {10, 60}, invite: {20, 86_400}]

  @doc """
  The `{limit, seconds}` budget for one group of auth requests.

  One reader for the whole key, so a group named here is a group every caller can ask for. The
  fallback is per group rather than for the key as a whole: configuring one budget replaces the
  list, and a list that then lacks a group must not make every request under it fail.
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

  # Each group has its own table and its own capacity, so a flood against one cannot refuse
  # another. A full table still refuses a key it has no room for, but only until its earliest
  # entry expires: the caller's window may be a day.
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

  # Drops what has expired and notes when the earliest remaining entry does.
  defp expire(keys, now) do
    Enum.reduce(keys, {%{}, nil}, fn
      {_key, {_count, until}}, acc when until <= now ->
        acc

      {key, {_count, until} = entry}, {kept, earliest} ->
        {Map.put(kept, key, entry), min(until, earliest || until)}
    end)
  end
end
