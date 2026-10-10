# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.PlayerDockLive do
  @moduledoc """
  Persistent player LiveView rendered in the root layout, outside the routed LiveView.

  This is the exception to the layout rule. Live navigation replaces only the routed LiveView.
  The media element in this LiveView therefore stays in the DOM across navigation.
  A moved YouTube iframe would reload and restart the video from the beginning.

  It runs its own authentication `on_mount` hook. It belongs to no route or `live_session`.
  """
  use SikioWeb, :live_view

  import SikioWeb.AudioFace
  import SikioWeb.MediaComponents

  alias Sikio.Chapters
  alias Sikio.Feeds
  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Playback

  # Declared here, because a LiveView rendered from the root layout belongs to no `live_session`.
  # Without `SikioWeb.Locale`, the dock renders in English while the page uses the session locale.
  on_mount {Ithibati.Web.Gate, {:require_account, to: "/login"}}
  on_mount {SikioWeb.Locale, :set}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe(socket.assigns.current_account)

    socket =
      assign(socket, entry: nil, player: nil, notice: nil, chapters: {nil, []})

    {:ok, rejoin(socket, get_connect_params(socket)), layout: false}
  end

  # LiveView mounts again after every reconnect. The connect params name the client's player.
  # The player is restored only if its session still owns the entry's playback.
  # The element then stays in the DOM and saves the position reached while offline.
  # If another session took over meanwhile, the dock shows the interrupted notice.
  defp rejoin(socket, %{"player_entry" => id, "player_session" => session})
       when is_binary(session) do
    case Library.entry(socket.assigns.current_account, id) do
      %{playback: %{session_id: ^session} = player} = entry ->
        socket |> assign(entry: entry, player: player) |> assign_chapters() |> fetch_media(entry)

      %{} = entry ->
        socket |> assign(:entry, entry) |> interrupted()

      nil ->
        socket
    end
  end

  defp rejoin(socket, _params), do: socket

  @impl true
  # `position` is optional. The card's cue can seek or skip before any media loads.
  def handle_event("start", %{"id" => id} = params, socket) do
    if socket.assigns.player && to_string(socket.assigns.entry.id) == to_string(id) do
      {:noreply, socket}
    else
      start_entry(socket, id, params["position"])
    end
  end

  # Sent when the current entry ends. With play-on enabled, starts the first other queued entry.
  # Without one the dock ends the session and closes, as after marking the entry by hand.
  def handle_event("next", _params, socket) do
    case next_in_queue(socket) do
      nil ->
        stop_current(socket)
        done_with(socket, nil)

      next ->
        start_entry(socket, next, nil)
    end
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
  def handle_info({event, state}, socket)
      when event in [:playback_changed, :playback_progressed] do
    entry = socket.assigns.entry

    if entry && entry.id == state.entry_id && Playback.newer?(entry, state),
      do: follow(socket, socket.assigns.player, state),
      else: {:noreply, socket}
  end

  # Ignored. If `mark_all/3` archived the playing entry, it cleared the session.
  # The player's next progress save then returns `:stale`.
  def handle_info({:playback_marked, _count}, socket), do: {:noreply, socket}

  # Tag and subscription setting changes affect library lists, not the current playback.
  def handle_info({:tags_changed, _subscription_id}, socket), do: {:noreply, socket}
  def handle_info({:subscription_changed, _subscription_id}, socket), do: {:noreply, socket}

  # A singly saved entry of the source stays in the library, so it plays on.
  def handle_info({:subscription_removed, feed_id}, socket) do
    entry = socket.assigns.entry

    if entry && entry.feed_id == feed_id && gone?(socket, entry),
      do: {:noreply, stop_with(socket, gettext("This source is no longer in your library."))},
      else: {:noreply, socket}
  end

  def handle_info({:entry_saved, _entry_id}, socket), do: {:noreply, socket}

  # A removed entry may still show through a subscription to its source.
  def handle_info({:entry_removed, entry_id}, socket) do
    entry = socket.assigns.entry

    if entry && to_string(entry.id) == to_string(entry_id) && gone?(socket, entry),
      do: {:noreply, stop_with(socket, gettext("This item is no longer in your library."))},
      else: {:noreply, socket}
  end

  defp gone?(socket, entry),
    do: is_nil(Library.visible_entry_id(socket.assigns.current_account, entry.id))

  defp stop_with(socket, notice) do
    stop_current(socket)
    assign(socket, entry: nil, player: nil, notice: notice)
  end

  # The change came from this dock's own session, or no player is active here.
  defp follow(socket, player, state) when is_nil(player) or player.session_id == state.session_id,
    do: {:noreply, assign_progress(socket, state)}

  # Marking an entry by hand clears its session. The dock treats it like a finished entry.
  defp follow(socket, _player, %{session_id: nil, status: status})
       when status in [:heard, :archived],
       do: done_with(socket, next_in_queue(socket))

  defp follow(socket, _player, %{session_id: nil, status: :new}), do: done_with(socket, nil)

  # Another session took over the entry's playback.
  defp follow(socket, _player, state),
    do: {:noreply, socket |> assign_progress(state) |> interrupted()}

  # Returns the first queued entry other than the current one, or nil when play-on is off.
  defp next_in_queue(socket) do
    account = socket.assigns.current_account
    current = socket.assigns.entry && socket.assigns.entry.id

    if Playback.play_on?(account),
      do: Enum.find(Playback.queue(account), &(&1 != current))
  end

  defp done_with(socket, nil),
    do: {:noreply, assign(socket, entry: nil, player: nil, notice: nil)}

  defp done_with(socket, next), do: start_entry(socket, next, nil)

  defp start_entry(socket, id, at) do
    account = socket.assigns.current_account

    with %{} = entry <- Library.entry(account, id),
         {:ok, player} <- Playback.start(account, id, at) do
      stop_current(socket)

      {:noreply,
       socket
       |> assign(entry: %{entry | playback: player}, player: player, notice: nil)
       |> assign_chapters()
       |> fetch_chapters(entry)
       |> fetch_media(entry)}
    else
      _ ->
        {:noreply, assign(socket, notice: gettext("This item is no longer in your library."))}
    end
  end

  # Chapter keys need the chapters, so an unfetched chapters file is fetched asynchronously.
  defp fetch_chapters(socket, %{chapters: nil, chapters_url: url} = entry) when is_binary(url),
    do: start_async(socket, :chapters, fn -> {entry.id, Feeds.chapters(entry)} end)

  defp fetch_chapters(socket, _entry), do: socket

  # A PeerTube feed names no stream. The instance's API names it on the first play.
  defp fetch_media(socket, %{feed: %{kind: :peertube}, media_url: nil} = entry),
    do: start_async(socket, :media, fn -> {entry.id, Feeds.media(entry)} end)

  defp fetch_media(socket, _entry), do: socket

  # A PeerTube video with Sikio's controls. The pending placeholder renders it without a source.
  # `playsinline` keeps the video in the dock on iOS. The MediaPlayer hook sets the source:
  # Safari plays the HLS playlist itself, other browsers through hls.js.
  attr :entry, :map, required: true
  attr :player, :map, required: true
  attr :chapters, :any, required: true
  attr :src, :string, default: nil

  defp video_frame(assigns) do
    ~H"""
    <video
      preload="metadata"
      playsinline
      data-src={@src}
      poster={artwork(@entry)}
      aria-label={@entry.title}
      class="aspect-video w-full rounded-control bg-black"
    ></video>
    <.audio_face
      length={@entry.duration}
      position={@player.position}
      chapters={elem(@chapters, 1)}
      sound={@entry.audio_url != nil}
    />
    """
  end

  # PeerTube's views API. The CSP's `connect-src` allows any HTTPS host.
  defp views_url(%{feed: %{kind: :peertube}, embed_url: embed}) do
    if api = Feeds.Discovery.video_api(embed), do: api <> "/views"
  end

  defp views_url(_entry), do: nil

  # The media element mounts once, so the player waits for a PeerTube file.
  defp playable?(%{feed: %{kind: :peertube}, media_url: url}), do: is_binary(url)
  defp playable?(_entry), do: true

  @impl true
  def handle_async(
        :chapters,
        {:ok, {id, {:ok, chapters}}},
        %{assigns: %{entry: %{id: id}}} = socket
      ),
      do: {:noreply, socket |> update(:entry, &%{&1 | chapters: chapters}) |> assign_chapters()}

  # The entry changed meanwhile, or the fetch failed. Chapters parsed from the notes stay.
  def handle_async(:chapters, _result, socket), do: {:noreply, socket}

  def handle_async(:media, {:ok, {id, {:ok, played}}}, %{assigns: %{entry: %{id: id}}} = socket),
    do:
      {:noreply,
       update(socket, :entry, &Map.merge(&1, Map.take(played, [:media_url, :audio_url])))}

  def handle_async(:media, {:ok, {id, _failed}}, %{assigns: %{entry: %{id: id}}} = socket),
    do:
      {:noreply,
       assign(
         socket,
         :notice,
         gettext("This video's instance could not be reached. Try again later.")
       )}

  # The entry changed meanwhile.
  def handle_async(:media, _result, socket), do: {:noreply, socket}

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
          gettext("Your progress changed in another player. Open the episode to continue here.")
      )

  defp assign_progress(socket, progress),
    do:
      socket |> assign(:entry, %{socket.assigns.entry | playback: progress}) |> assign_chapters()

  # Uses the privacy-enhanced host. `enablejsapi` allows reading the position back.
  # YouTube accepts postMessage calls from this page only when `origin` is set.
  # `cc_load_policy=0` requests no captions. YouTube does not always honor it.
  # See assets/js/media_player.mjs.
  defp youtube_url(entry, player) do
    query =
      URI.encode_query(%{
        autoplay: 1,
        cc_load_policy: 0,
        enablejsapi: 1,
        origin: SikioWeb.Endpoint.url(),
        playsinline: 1,
        start: trunc(player.position),
        rel: 0
      })

    "https://www.youtube-nocookie.com/embed/#{entry.video_id}?#{query}"
  end

  # Assigns chapters for the chapter keys and the audio face's marks.
  # It uses `Chapters.of/2` like the detail view, with the measured duration when present.
  # Progress updates replace the entry every few seconds.
  # The notes are parsed again only when the cache key changes.
  defp assign_chapters(%{assigns: %{entry: entry, chapters: {read, _starts}}} = socket) do
    length = (entry.playback && entry.playback.duration) || entry.duration
    key = {entry.id, entry.description, length, entry.chapters}

    if key == read do
      socket
    else
      {chapters, _notes} = Chapters.of(entry, length)
      assign(socket, :chapters, {key, chapters})
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="player-control" phx-hook="PlayerDock" data-entry-id={@player && @entry.id}>
      <%!-- Positions the panel beside the content columns; see assets/js/dock_place.mjs. --%>
      <div id="dock-place" phx-hook="DockPlace" hidden></div>
      <aside
        :if={@entry || @notice}
        id="player-panel"
        phx-mounted={JS.ignore_attributes(["style", "data-place", "data-stuck"])}
        aria-label={gettext("Now playing")}
        tabindex="-1"
        class="fixed right-4 bottom-4 left-4 z-40 max-h-[85vh] overflow-y-auto rounded-control border border-line bg-surface p-5 shadow-xl sm:left-auto sm:w-[400px]"
      >
        <%!-- On a phone, outside the entry's detail view, app.css shows the panel as a capsule
             above the tab bar: artwork or video, title, play/pause and close. --%>
        <div class="player-heading mb-4 flex items-start justify-between gap-3">
          <img
            :if={@entry && @entry.feed.kind == :podcast}
            id="capsule-art"
            src={artwork(@entry)}
            alt=""
            class="hidden"
          />
          <div :if={@entry} class="player-text mr-auto min-w-0">
            <p class="player-source text-meta font-semibold text-muted">
              {source_name(@entry)}
            </p>
            <.link
              navigate={
                SikioWeb.LibraryPaths.library_path(
                  %{"source" => to_string(@entry.feed_id)},
                  @entry,
                  %{@entry.feed_id => source_name(@entry)}
                )
              }
              data-show-entry={@entry.id}
              class="player-title mt-1 block text-label leading-snug font-semibold break-words"
            >{@entry.title}</.link>
            <p class="player-status mt-2 text-meta text-muted">
              {status_label(@entry)} ·
              <span class="font-mono">{timestamp(@entry.playback.position)}</span>
            </p>
          </div>
          <%!-- Dispatches the same `toggle` command as the keyboard shortcut. The MediaPlayer
               hook sets `data-playing`, which switches the icon. --%>
          <button
            :if={@player}
            id="capsule-play"
            type="button"
            phx-click={
              JS.dispatch("sikio:command",
                to: "#player-#{@player.session_id}",
                detail: %{name: "toggle"}
              )
            }
            aria-label={gettext("Play or pause")}
            class="hidden size-11 shrink-0 items-center justify-center rounded-full text-ink hover:bg-ground"
          >
            <Lucideicons.play aria-hidden="true" class="capsule-icon-play size-5 fill-current" />
            <Lucideicons.pause aria-hidden="true" class="capsule-icon-pause size-5 fill-current" />
          </button>
          <button
            id="close-player"
            phx-click={JS.dispatch("sikio:close-player")}
            aria-label={gettext("Close player")}
            class="flex size-11 shrink-0 items-center justify-center rounded-full p-2 text-muted hover:bg-ground"
          >
            <Lucideicons.x aria-hidden="true" class="size-5" />
          </button>
        </div>
        <p
          :if={@notice}
          id="dock-notice"
          role="status"
          class="mb-4 text-label text-warning"
        >
          {@notice}
        </p>
        <%!-- Stands in for the player while the instance's API names the playlist. Same markup
        as the player, so the panel does not change its height when the player replaces it. --%>
        <div :if={@player && !playable?(@entry) && !@notice} id="player-pending">
          <.video_frame entry={@entry} player={@player} chapters={@chapters} />
        </div>
        <div
          :if={@player && playable?(@entry)}
          id={"player-#{@player.session_id}"}
          phx-hook="MediaPlayer"
          phx-update="ignore"
          data-kind={@entry.feed.kind}
          data-audio-src={@entry.audio_url}
          data-views={views_url(@entry)}
          data-hls={@entry.feed.kind == :peertube && ~p"/vendor/hls.js/hls-1.7.3.min.js"}
          data-session={@player.session_id}
          data-title={@entry.title}
          data-source={source_name(@entry)}
          data-artwork={artwork(@entry)}
          data-position={@player.position}
          data-stale={gettext("Your progress changed elsewhere. Press Play to continue here.")}
          data-disconnected={
            gettext(
              "Connection lost. Playback paused; your latest position will save when reconnected."
            )
          }
          data-reconnect-first={
            gettext("Reconnect before switching or closing, so your place can be saved.")
          }
          data-ready-audio-manual={gettext("The browser did not start it. Press play.")}
          data-audio-failed={
            gettext(
              "This audio could not be loaded. The publisher may be unavailable or the format unsupported. Try again later."
            )
          }
          data-video-failed={
            gettext(
              "This video could not be loaded. The instance may be unavailable. Try again later."
            )
          }
          data-youtube-unavailable={
            gettext("YouTube could not be loaded. Check your connection or content blocker.")
          }
          data-youtube-missing={gettext("This video is private or has been removed.")}
          data-youtube-blocked={gettext("This video cannot be embedded. You can open it on YouTube.")}
          data-youtube-origin={
            gettext(
              "YouTube could not identify this site. Check browser privacy settings or open it on YouTube."
            )
          }
          data-chapters={@chapters |> elem(1) |> Jason.encode!()}
          data-label-play={gettext("Play")}
          data-label-pause={gettext("Pause")}
          data-position-of={
            gettext("%{position} of %{duration}", position: "{position}", duration: "{duration}")
          }
          data-locale={Gettext.get_locale(SikioWeb.Gettext)}
          data-youtube-unplayable={
            gettext("YouTube cannot play this video. Try opening it on YouTube.")
          }
        >
          <%!-- Audio and PeerTube video have no native controls. The audio face controls them; see
          assets/js/audio_face.mjs. app.css holds its layout for each `data-place`. --%>
          <audio
            :if={@entry.feed.kind == :podcast}
            preload="metadata"
            src={@entry.media_url}
            aria-label={@entry.title}
          ></audio>
          <.audio_face
            :if={@entry.feed.kind == :podcast}
            length={@entry.duration}
            position={@player.position}
            chapters={elem(@chapters, 1)}
          />
          <.video_frame
            :if={@entry.feed.kind == :peertube}
            entry={@entry}
            player={@player}
            chapters={@chapters}
            src={@entry.media_url}
          />
          <iframe
            :if={@entry.feed.kind == :youtube}
            id={"youtube-#{@player.session_id}"}
            src={youtube_url(@entry, @player)}
            title={@entry.title}
            class="aspect-video min-h-[200px] w-full"
            referrerpolicy="strict-origin-when-cross-origin"
            allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
            allowfullscreen
          ></iframe>
          <%!-- Empty during playback. The MediaPlayer hook writes warnings and errors here. --%>
          <p data-player-message role="status" class="mt-4 text-label text-muted"></p>
          <%!-- Progress line at the capsule's bottom. The MediaPlayer hook sets --played. --%>
          <span data-progress aria-hidden="true" class="hidden"></span>
        </div>
      </aside>
    </div>
    """
  end
end
