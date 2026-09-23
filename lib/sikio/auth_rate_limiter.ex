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
    |> Keyword.get(group) || Keyword.fetch!(@defaults, group)
  end

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
