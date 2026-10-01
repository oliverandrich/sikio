# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlayerLive do
  @moduledoc """
  One item, its personal status, and the button that hands it to the player.

  This page never holds the media itself. Pressing play dispatches a browser event that the dock in
  the root layout picks up, so navigating away from here does not interrupt anything.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents

  alias Sikio.Library
  alias Sikio.Playback

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Library.entry(socket.assigns.current_account, id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/")}

      entry ->
        {:ok, assign(socket, page_title: entry.title, entry: entry)}
    end
  end

  @impl true
  def handle_event("mark", %{"status" => status}, socket) when status in ["new", "completed"] do
    state = if status == "new", do: :new, else: :completed

    case Playback.mark(socket.assigns.current_account, socket.assigns.entry.id, state) do
      {:ok, progress} -> {:noreply, assign_progress(socket, progress)}
      {:error, _} -> {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  # A notification older than what is already on screen is dropped. Otherwise a late message from a
  # player that has since been replaced would undo a status somebody just set by hand.
  #
  # Library events arrive here through `SikioWeb.Sidebar`.
  def handle_library_event({:playback_changed, state}, socket) do
    entry = socket.assigns.entry

    if entry.id == state.entry_id and Playback.newer?(entry, state) do
      {:noreply, assign_progress(socket, state)}
    else
      {:noreply, socket}
    end
  end

  def handle_library_event({:subscription_removed, feed_id}, socket) do
    if socket.assigns.entry.feed_id == feed_id,
      do: {:noreply, push_navigate(socket, to: ~p"/")},
      else: {:noreply, socket}
  end

  # New episodes elsewhere change nothing on an item that is already open.
  def handle_library_event(:library_changed, socket), do: {:noreply, socket}

  defp assign_progress(socket, progress) do
    assign(socket, :entry, %{socket.assigns.entry | playback: progress})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member flash={@flash} current_account={@current_account} sidebar={@sidebar}>
      <.link navigate={~p"/"} class="text-sm font-semibold text-teal-800 dark:text-teal-300">
        {gettext("← Your library")}
      </.link>
      <div class="mx-auto mt-10 max-w-3xl">
        <p class="text-xs font-semibold tracking-widest text-teal-800 uppercase dark:text-teal-300">
          {@entry.feed.title}
        </p>
        <h1 class="font-display mt-4 text-3xl leading-tight sm:text-5xl">{@entry.title}</h1>
        <p
          id="playback-status"
          class="mt-5 text-sm text-stone-600 dark:text-stone-300"
          aria-live="polite"
        >
          {status_label(@entry)}
          <span :if={@entry.playback && @entry.playback.position > 0}>
            · {gettext("Saved at %{time}", time: timestamp(@entry.playback.position))}
          </span>
        </p>
        <section
          class="mt-8 rounded-3xl border border-stone-200 bg-white p-4 sm:p-8 dark:border-stone-800 dark:bg-stone-900"
          aria-label={gettext("Player")}
        >
          <div class="py-10 text-center">
            <.button
              id="start-playback"
              variant="primary"
              phx-click={JS.dispatch("sikio:play", detail: %{id: @entry.id})}
            >
              <Lucideicons.play aria-hidden="true" class="size-5 fill-current" />
              {play_label(@entry)}
            </.button>
            <p class="mx-auto mt-5 max-w-sm text-sm leading-relaxed text-stone-500 dark:text-stone-400">
              {privacy_note(@entry)}
            </p>
          </div>
        </section>
        <div class="mt-6 flex flex-wrap items-center gap-5 text-sm">
          <button
            :if={status(@entry) != :completed}
            id="mark-completed"
            phx-click="mark"
            phx-value-status="completed"
            class="min-h-11 font-semibold text-teal-800 dark:text-teal-300"
          >{mark_done_label(@entry)}</button>
          <button
            :if={status(@entry) != :new}
            id="mark-new"
            phx-click="mark"
            phx-value-status="new"
            class="min-h-11 font-semibold text-teal-800 dark:text-teal-300"
          >{mark_new_label(@entry)}</button>
          <a
            :if={@entry.feed.kind == :youtube}
            id="open-original"
            href={"https://www.youtube.com/watch?v=#{@entry.video_id}"}
            target="_blank"
            rel="noopener noreferrer"
            class="min-h-11 text-stone-600 dark:text-stone-300"
          >{gettext("Open on YouTube ↗")}</a>
        </div>
        <p class="mt-6 text-xs leading-relaxed text-stone-500 dark:text-stone-400">
          {gettext(
            "Playback stays with you as you browse your library and subscriptions. Your place is saved every five seconds, on pause and after seeking. Reaching the end marks this item complete. You can always change that yourself."
          )}
        </p>
      </div>
    </Layouts.member>
    """
  end
end
