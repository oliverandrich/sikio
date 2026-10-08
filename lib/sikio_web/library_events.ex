# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryEvents do
  @moduledoc """
  Library PubSub events for member pages, as an `on_mount` hook of the `:members` live_session.

  It subscribes to the account's library events and refreshes the sidebar on them.
  New episodes arrive in bursts, from an import or a poll of many feeds.
  The first `:library_changed` refreshes at once and opens a one-second window.
  Further ones inside the window cause one refresh when it closes.
  That refresh opens the next window.

  A LiveView that needs the events implements this behaviour's `handle_library_event/2`.
  It returns the same tuples as `handle_info/2`. The view's own `handle_info/2` does not get them.
  """
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, put_private: 3]

  alias Sikio.Library.Events
  alias SikioWeb.Sidebar

  @callback handle_library_event(message :: term(), Phoenix.LiveView.Socket.t()) ::
              {:noreply, Phoenix.LiveView.Socket.t()}

  @window_ms 1000

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Events.subscribe(socket.assigns.current_account)
      Events.subscribe_updates(socket.assigns.current_account)
    end

    {:cont,
     socket
     |> put_private(:library_window, :closed)
     |> attach_hook(:library_events, :handle_info, &follow/2)}
  end

  # The window state lives in `socket.private`, because an assign change would trigger a render.
  defp follow(:library_changed, %{private: %{library_window: :closed}} = socket),
    do: {:halt, socket |> Sidebar.refresh() |> passed_on(:library_changed) |> open_window()}

  defp follow(:library_changed, socket),
    do: {:halt, put_private(socket, :library_window, :pending)}

  defp follow(:library_window_closed, %{private: %{library_window: :pending}} = socket),
    do: follow(:library_changed, put_private(socket, :library_window, :closed))

  defp follow(:library_window_closed, socket),
    do: {:halt, put_private(socket, :library_window, :closed)}

  defp follow(message, socket) do
    if library_event?(message),
      do: {:halt, socket |> refresh_for(message) |> passed_on(message)},
      else: {:cont, socket}
  end

  defp open_window(socket) do
    Process.send_after(self(), :library_window_closed, @window_ms)
    put_private(socket, :library_window, :open)
  end

  # Counts depend on statuses only. The player saves progress every few seconds without a status
  # change, so `:playback_progressed` skips the refresh.
  defp refresh_for(socket, {:playback_progressed, _state}), do: socket
  defp refresh_for(socket, _message), do: Sidebar.refresh(socket)

  defp library_event?({:playback_progressed, _state}), do: true
  defp library_event?({:playback_changed, _state}), do: true
  defp library_event?({:subscription_removed, _feed_id}), do: true
  defp library_event?({:playback_marked, _count}), do: true
  defp library_event?({:tags_changed, _subscription_id}), do: true
  defp library_event?({:subscription_changed, _subscription_id}), do: true
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
