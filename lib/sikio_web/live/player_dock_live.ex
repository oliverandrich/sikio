defmodule SikioWeb.PlayerDockLive do
  @moduledoc """
  An independently authenticated, persistent player outside routed page content.

  This is the exception to the application's layout rule, and the reason is the DOM. It renders
  into the root layout rather than inside the navigated view, so moving between the library, an
  item and the subscriptions never touches the element holding the media. A YouTube iframe that
  moved would reload, and a reloaded iframe is a video starting again from the top.

  It authenticates itself, because a LiveView mounted outside the routed one gets no account from
  the route it is not on.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents

  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Playback

  on_mount {Ithibati.Web.Gate, {:require_account, to: "/login"}}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe(socket.assigns.current_account)
    {:ok, assign(socket, entry: nil, player: nil, notice: nil, compact: false), layout: false}
  end

  @impl true
  def handle_event("start", %{"id" => id}, socket) do
    if socket.assigns.player && to_string(socket.assigns.entry.id) == to_string(id) do
      {:reply, %{started: true}, socket}
    else
      start_entry(socket, id)
    end
  end

  def handle_event("compact", _params, socket) do
    {:noreply, assign(socket, :compact, not socket.assigns.compact)}
  end

  def handle_event("close", _params, socket) do
    stop_current(socket)
    {:reply, %{closed: true}, assign(socket, entry: nil, player: nil, notice: nil)}
  end

  def handle_event("progress", %{"session" => session} = params, socket) do
    if socket.assigns.player && socket.assigns.player.session_id == session do
      save_progress(socket, session, params)
    else
      {:reply, %{saved: false}, socket}
    end
  end

  def handle_event("progress", _params, socket), do: {:reply, %{saved: false}, socket}

  @impl true
  def handle_info({:playback_changed, state}, socket) do
    entry = socket.assigns.entry

    if entry && entry.id == state.entry_id && Playback.newer?(entry, state) do
      player = socket.assigns.player

      if player && player.session_id != state.session_id do
        {:noreply, socket |> assign_progress(state) |> interrupted()}
      else
        {:noreply, assign_progress(socket, state)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:subscription_removed, feed_id}, socket) do
    if socket.assigns.entry && socket.assigns.entry.feed_id == feed_id do
      stop_current(socket)

      {:noreply,
       assign(socket,
         entry: nil,
         player: nil,
         notice: gettext("This source is no longer in your library.")
       )}
    else
      {:noreply, socket}
    end
  end

  defp start_entry(socket, id) do
    account = socket.assigns.current_account

    with %{} = entry <- Library.entry(account, id),
         {:ok, player} <- Playback.start(account, id) do
      stop_current(socket)

      {:reply, %{started: true},
       assign(socket, entry: %{entry | playback: player}, player: player, notice: nil)}
    else
      _ ->
        {:reply, %{started: false},
         assign(socket, notice: gettext("This item is no longer in your library."))}
    end
  end

  defp stop_current(%{assigns: %{player: nil}}), do: :ok

  defp stop_current(socket),
    do:
      Playback.stop(
        socket.assigns.current_account,
        socket.assigns.entry.id,
        socket.assigns.player.session_id
      )

  defp save_progress(socket, session, params) do
    case Playback.save(socket.assigns.current_account, socket.assigns.entry.id, session, params) do
      {:ok, progress} -> {:reply, %{saved: true}, assign_progress(socket, progress)}
      {:error, :stale} -> {:reply, %{saved: false}, interrupted(socket)}
      {:error, _} -> {:reply, %{saved: false}, socket}
    end
  end

  defp interrupted(socket),
    do:
      assign(socket,
        player: nil,
        notice:
          gettext(
            "Your progress changed in another player or was marked manually. Open the episode to continue here."
          )
      )

  defp assign_progress(socket, progress),
    do: assign(socket, :entry, %{socket.assigns.entry | playback: progress})

  # The privacy-enhanced host, and the API enabled so the position can be read back. `origin` is
  # what lets YouTube accept messages from this page at all.
  defp youtube_url(entry, player) do
    query =
      URI.encode_query(%{
        enablejsapi: 1,
        origin: SikioWeb.Endpoint.url(),
        playsinline: 1,
        start: trunc(player.position),
        rel: 0
      })

    "https://www.youtube-nocookie.com/embed/#{entry.video_id}?#{query}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="player-control" phx-hook="PlayerDock" data-entry-id={@player && @entry.id}>
      <aside
        :if={@entry || @notice}
        id="player-panel"
        aria-label={gettext("Now playing")}
        tabindex="-1"
        class={[
          "fixed right-4 bottom-4 left-4 z-40 max-h-[85vh] overflow-y-auto rounded-2xl border border-stone-200 bg-white p-5 shadow-xl sm:left-auto sm:w-[400px] dark:border-stone-700 dark:bg-stone-900",
          @entry && @entry.feed.kind == :youtube && "has-video",
          @compact && @entry && @entry.feed.kind == :podcast && "compact-audio"
        ]}
      >
        <div class="player-heading mb-4 flex items-start justify-between gap-3">
          <div :if={@entry} class="min-w-0">
            <p class="player-source text-xs font-semibold text-teal-800 dark:text-teal-300">
              {@entry.feed.title}
            </p>
            <.link
              navigate={~p"/library/#{@entry.id}"}
              class="player-title mt-1 block text-sm leading-snug font-semibold break-words"
            >{@entry.title}</.link>
            <p class="player-status mt-2 text-xs text-stone-500 dark:text-stone-400">
              {status_label(@entry)} · {timestamp(@entry.playback.position)}
            </p>
          </div>
          <button
            :if={@entry && @entry.feed.kind == :podcast}
            id="compact-player"
            phx-click="compact"
            aria-pressed={to_string(@compact)}
            aria-label={if @compact, do: gettext("Expand player"), else: gettext("Compact player")}
            class="flex size-11 shrink-0 items-center justify-center rounded-full text-stone-500 hover:bg-stone-100 dark:hover:bg-stone-800"
          >
            <Lucideicons.chevron_up :if={@compact} aria-hidden="true" class="size-5" />
            <Lucideicons.chevron_down :if={!@compact} aria-hidden="true" class="size-5" />
          </button>
          <button
            id="close-player"
            phx-click={JS.dispatch("sikio:close-player")}
            aria-label={gettext("Close player")}
            class="flex size-11 shrink-0 items-center justify-center rounded-full p-2 text-stone-500 hover:bg-stone-100 dark:hover:bg-stone-800"
          >
            <Lucideicons.x aria-hidden="true" class="size-5" />
          </button>
        </div>
        <p
          :if={@notice}
          id="dock-notice"
          role="status"
          class="mb-4 text-sm text-amber-800 dark:text-amber-300"
        >
          {@notice}
        </p>
        <div
          :if={@player}
          id={"player-#{@player.session_id}"}
          phx-hook="MediaPlayer"
          phx-update="ignore"
          data-kind={@entry.feed.kind}
          data-session={@player.session_id}
          data-position={@player.position}
        >
          <audio
            :if={@entry.feed.kind == :podcast}
            controls
            preload="metadata"
            src={@entry.media_url}
            class="w-full"
            aria-label={@entry.title}
          ></audio>
          <div
            :if={@entry.feed.kind == :podcast}
            class="player-speed mt-5 flex items-center gap-3 text-sm"
          >
            <label for="playback-speed">{gettext("Speed")}</label>
            <select
              id="playback-speed"
              class="rounded-lg border border-stone-300 px-3 py-2 dark:border-stone-700 dark:bg-stone-800"
            >
              <option
                :for={speed <- [0.75, 1, 1.25, 1.5, 1.75, 2]}
                value={speed}
                selected={speed == 1}
              >
                {speed}×
              </option>
            </select>
          </div>
          <iframe
            :if={@entry.feed.kind == :youtube}
            id={"youtube-#{@player.session_id}"}
            src={youtube_url(@entry, @player)}
            title={@entry.title}
            class="aspect-video min-h-[200px] w-full rounded-xl"
            referrerpolicy="strict-origin-when-cross-origin"
            allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
            allowfullscreen
          ></iframe>
          <p data-player-message role="status" class="mt-4 text-sm text-stone-600 dark:text-stone-300">
            {gettext("Loading player…")}
          </p>
        </div>
      </aside>
    </div>
    """
  end
end
