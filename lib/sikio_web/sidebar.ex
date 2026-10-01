# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.Sidebar do
  @moduledoc """
  What the reader's sidebar shows: the sources and how many items each view holds.

  Mounted for every member page, so a page that is not the library still shows where things
  stand. It listens to the library's events itself and refreshes on each of them.

  A view that wants the events as well defines `handle_library_event/2`, which answers like
  `handle_info/2`. Its own `handle_info/2` never sees them.
  """
  use SikioWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Sikio.Library
  alias Sikio.Library.Events

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Events.subscribe(socket.assigns.current_account)
      Events.subscribe_updates(socket.assigns.current_account)
    end

    {:cont, socket |> refresh() |> attach_hook(:sidebar, :handle_info, &follow/2)}
  end

  @doc "Reads the counts and sources again."
  def refresh(socket) do
    account = socket.assigns.current_account

    sources =
      account
      |> Library.subscriptions()
      |> Enum.sort_by(&String.downcase(&1.feed.title || ""))

    assign(socket, :sidebar, %{counts: Library.counts(account), sources: sources})
  end

  @doc "The library's address under `filters`, at an item when `id` is given; empty filters are left out."
  def library_path(filters, id \\ nil) do
    query = filters |> Enum.reject(fn {_key, value} -> value in [nil, ""] end) |> Map.new()

    case {id, query == %{}} do
      {nil, true} -> ~p"/"
      {nil, false} -> ~p"/?#{query}"
      {id, true} -> ~p"/library/#{id}"
      {id, false} -> ~p"/library/#{id}?#{query}"
    end
  end

  @doc """
  The library's address with one filter changed and the others kept.

  A status is set; a kind or a source chosen again is let go, so the same link narrows and widens.
  """
  def filter_path(filters, "status", value),
    do: filters |> Map.put("status", value) |> library_path()

  def filter_path(filters, key, value) do
    value = if filters[key] == value, do: "", else: value
    filters |> Map.put(key, value) |> library_path()
  end

  defp follow(message, socket) do
    if library_event?(message),
      do: {:halt, socket |> refresh_for(message) |> passed_on(message)},
      else: {:cont, socket}
  end

  # The counts follow statuses, and a player saves its place every few seconds without changing
  # one. Only a changed status is worth reading them again.
  defp refresh_for(socket, {:playback_progressed, _state}), do: socket
  defp refresh_for(socket, _message), do: refresh(socket)

  defp library_event?({:playback_progressed, _state}), do: true
  defp library_event?({:playback_changed, _state}), do: true
  defp library_event?({:subscription_removed, _feed_id}), do: true
  defp library_event?(:library_changed), do: true
  defp library_event?(_message), do: false

  defp passed_on(socket, message) do
    if function_exported?(socket.view, :handle_library_event, 2) do
      {:noreply, socket} = socket.view.handle_library_event(message, socket)
      socket
    else
      socket
    end
  end
end
