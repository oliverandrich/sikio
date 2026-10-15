# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.TransportGarbage do
  @moduledoc """
  Asks a page's WebSocket process to collect garbage once the page has joined.

  Sending the first render grows that process's heap to about a megabyte. Afterwards it only
  passes heartbeats and small diffs, so it allocates too little to trigger a collection and keeps
  the heap. `Phoenix.Socket` documents `:garbage_collect` for this case.

  It is an `on_mount` hook of the `:members` live_session. The message to itself arrives after
  the join reply has gone to the transport, so the collection follows the reply.
  """
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, detach_hook: 3]

  def on_mount(:collect, _params, _session, socket),
    do: {:cont, if(enabled?(), do: schedule(socket), else: socket)}

  defp enabled?, do: Application.get_env(:sikio, :collect_transport_garbage, true)

  @doc false
  def schedule(socket) do
    if connected?(socket) do
      send(self(), {__MODULE__, :collect})
      attach_hook(socket, :transport_garbage, :handle_info, &collect/2)
    else
      socket
    end
  end

  @doc false
  def collect({__MODULE__, :collect}, socket) do
    send(socket.transport_pid, :garbage_collect)
    {:halt, detach_hook(socket, :transport_garbage, :handle_info)}
  end

  def collect(_message, socket), do: {:cont, socket}
end
