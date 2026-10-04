# SPDX-License-Identifier: AGPL-3.0-or-later

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

  import SikioWeb.AudioFace
  import SikioWeb.MediaComponents

  alias Sikio.Chapters
  alias Sikio.Feeds
  alias Sikio.Library
  alias Sikio.Library.Events
  alias Sikio.Playback
  alias SikioWeb.Pictures

  # Both hooks by hand, because rendering from the root layout means belonging to no live_session
  # and inheriting nothing from one. Without the second, this dock answers a German session in
  # English while the page around it is translated.
  on_mount {Ithibati.Web.Gate, {:require_account, to: "/login"}}
  on_mount {SikioWeb.Locale, :set}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Events.subscribe(socket.assigns.current_account)

    socket =
      assign(socket, entry: nil, player: nil, notice: nil, chapters: {nil, "[]"})

    {:ok, rejoin(socket, get_connect_params(socket)), layout: false}
  end

  # LiveView mounts again after every reconnect, and the browser names the player it still holds.
  # That player is taken back only while its session owns the entry, so the element stays on the
  # page and saves the position it kept while offline. A session taken over in the meantime is
  # reported like any other.
  defp rejoin(socket, %{"player_entry" => id, "player_session" => session})
       when is_binary(session) do
    case Library.entry(socket.assigns.current_account, id) do
      %{playback: %{session_id: ^session} = player} = entry ->
        socket |> assign(entry: entry, player: player) |> assign_chapters()

      %{} = entry ->
        socket |> assign(:entry, entry) |> interrupted()

      nil ->
        socket
    end
  end

  defp rejoin(socket, _params), do: socket

  @impl true
  # The card's player may name a place: it can be dragged or skipped before anything loads.
  def handle_event("start", %{"id" => id} = params, socket) do
    if socket.assigns.player && to_string(socket.assigns.entry.id) == to_string(id) do
      {:noreply, socket}
    else
      start_entry(socket, id, params["position"])
    end
  end

  # The item that played has ended. Playing on, the first in the queue follows it; the one that
  # ended has left the queue as it was heard.
  def handle_event("next", _params, socket) do
    account = socket.assigns.current_account
    current = socket.assigns.entry && socket.assigns.entry.id

    case Playback.play_on?(account) && Enum.reject(Playback.queue(account), &(&1 == current)) do
      [next | _] -> start_entry(socket, next, nil)
      _ -> {:noreply, socket}
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

  # A whole list marked finished leaves out what a player holds, so the dock has nothing to do.
  def handle_info({:playback_marked, _count}, socket), do: {:noreply, socket}

  # Tags change what the library lists, never what plays.
  def handle_info({:tags_changed, _subscription_id}, socket), do: {:noreply, socket}

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

  defp start_entry(socket, id, at) do
    account = socket.assigns.current_account

    with %{} = entry <- Library.entry(account, id),
         {:ok, player} <- Playback.start(account, id, at) do
      stop_current(socket)

      {:noreply,
       socket
       |> assign(entry: %{entry | playback: player}, player: player, notice: nil)
       |> assign_chapters()
       |> fetch_chapters(entry)}
    else
      _ ->
        {:noreply, assign(socket, notice: gettext("This item is no longer in your library."))}
    end
  end

  # The keys move between chapters, so a chapters file nobody fetched yet is fetched here.
  defp fetch_chapters(socket, %{chapters: nil, chapters_url: url} = entry) when is_binary(url),
    do: start_async(socket, :chapters, fn -> {entry.id, Feeds.chapters(entry)} end)

  defp fetch_chapters(socket, _entry), do: socket

  @impl true
  def handle_async(
        :chapters,
        {:ok, {id, {:ok, chapters}}},
        %{assigns: %{entry: %{id: id}}} = socket
      ),
      do: {:noreply, socket |> update(:entry, &%{&1 | chapters: chapters}) |> assign_chapters()}

  # Another item plays by now, or the file could not be read: the keys keep the notes' chapters.
  def handle_async(:chapters, _result, socket), do: {:noreply, socket}

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
    do:
      socket |> assign(:entry, %{socket.assigns.entry | playback: progress}) |> assign_chapters()

  # The address the feed named, with what the embed needs from us: permission to speak through
  # its api, to start at once, and the second to resume at. Peer to peer stays off, so the
  # instance alone serves the video: a mirror it names may fail, and peers would see the viewer's
  # address. Nothing here is built out of host and id, so a
  # release that spells its own addresses differently keeps working. What it named may already
  # carry a query, and a second question mark would hide everything this adds.
  defp peertube_url(entry, player) do
    entry.embed_url
    |> URI.parse()
    |> URI.append_query(
      URI.encode_query(%{api: 1, autoplay: 1, p2p: 0, start: trunc(player.position)})
    )
    |> URI.to_string()
  end

  # The privacy-enhanced host, and the API enabled so the position can be read back. `origin` is
  # what lets YouTube accept messages from this page at all.
  defp youtube_url(entry, player) do
    query =
      URI.encode_query(%{
        autoplay: 1,
        enablejsapi: 1,
        origin: SikioWeb.Endpoint.url(),
        playsinline: 1,
        start: trunc(player.position),
        rel: 0
      })

    "https://www.youtube-nocookie.com/embed/#{entry.video_id}?#{query}"
  end

  # Where the chapters of what plays begin, for the keys that move between them. The same rule as
  # the detail's list; the length a player measured counts here as there. Progress replaces the
  # entry every few seconds, so the notes are read again only when what they depend on changed.
  defp assign_chapters(%{assigns: %{entry: entry, chapters: {read, _starts}}} = socket) do
    length = (entry.playback && entry.playback.duration) || entry.duration
    key = {entry.id, entry.description, length, entry.chapters}

    if key == read do
      socket
    else
      {chapters, _notes} = Chapters.of(entry, length)
      assign(socket, :chapters, {key, chapters |> Enum.map(& &1.at) |> Jason.encode!()})
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="player-control" phx-hook="PlayerDock" data-entry-id={@player && @entry.id}>
      <%!-- Places the panel beside the reader's columns; see assets/js/dock_place.mjs. --%>
      <div id="dock-place" phx-hook="DockPlace" hidden></div>
      <aside
        :if={@entry || @notice}
        id="player-panel"
        phx-mounted={JS.ignore_attributes(["style", "data-place", "data-stuck"])}
        aria-label={gettext("Now playing")}
        tabindex="-1"
        class="fixed right-4 bottom-4 left-4 z-40 max-h-[85vh] overflow-y-auto rounded-control border border-line bg-surface p-5 shadow-xl sm:left-auto sm:w-[400px]"
      >
        <%!-- On a phone, away from its item, the panel is a capsule above the tab bar: the
             picture or the video, what plays, play or pause and close. See app.css. --%>
        <div class="player-heading mb-4 flex items-start justify-between gap-3">
          <img
            :if={@entry && @entry.feed.kind == :podcast}
            id="capsule-art"
            src={Pictures.path(Sikio.Pictures.candidates(@entry), kind_mark(@entry))}
            alt=""
            class="hidden"
          />
          <div :if={@entry} class="player-text mr-auto min-w-0">
            <p class="player-source text-meta font-semibold text-muted">
              {source_name(@entry)}
            </p>
            <.link
              navigate={
                SikioWeb.Sidebar.library_path(
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
          <%!-- Drives the player as the keyboard does; the player says whether it plays. --%>
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
        <div
          :if={@player}
          id={"player-#{@player.session_id}"}
          phx-hook="MediaPlayer"
          phx-update="ignore"
          data-kind={@entry.feed.kind}
          data-session={@player.session_id}
          data-title={@entry.title}
          data-source={source_name(@entry)}
          data-artwork={Pictures.path(Sikio.Pictures.candidates(@entry), kind_mark(@entry))}
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
          data-peertube-unavailable={
            gettext("This instance could not be reached. It may be down or blocking this page.")
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
          data-chapters={elem(@chapters, 1)}
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
          <%!-- The audio element keeps no controls of its own. Sikio's face drives it; see
          assets/js/audio_face.mjs. Its layout for each place is in app.css. --%>
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
          />
          <iframe
            :if={@entry.feed.kind == :peertube}
            id={"peertube-#{@player.session_id}"}
            src={peertube_url(@entry, @player)}
            title={@entry.title}
            class="aspect-video min-h-[200px] w-full"
            referrerpolicy="strict-origin-when-cross-origin"
            allow="autoplay; encrypted-media; picture-in-picture; fullscreen"
            allowfullscreen
          ></iframe>
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
          <%!-- Empty while the player works; warnings and errors go here. --%>
          <p data-player-message role="status" class="mt-4 text-label text-muted"></p>
          <%!-- How far it has come, a line along the capsule's foot; the player sets --played. --%>
          <span data-progress aria-hidden="true" class="hidden"></span>
        </div>
      </aside>
    </div>
    """
  end
end
