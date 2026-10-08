# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryComponents do
  @moduledoc """
  Function components of the library page: list rows, menus, playback status and the detail.
  """
  use SikioWeb, :html

  import SikioWeb.AudioFace
  import SikioWeb.MediaComponents

  alias Sikio.Playback
  alias SikioWeb.Pictures

  @doc "Returns a list row's DOM id, which is also its comprehension key."
  def row_id({:heading, {year, month}, _label}), do: "group-#{year}-#{month}"
  def row_id({:heading, key, _label}), do: "group-#{key}"
  def row_id({:entry, entry}), do: "entries-#{entry.id}"

  # Renders a date heading or an entry row. From `lg` headings are sticky below the list head.
  # assets/js/list_head.mjs sets `--list-head` to the head's height.
  attr :row, :any, required: true
  attr :filters, :map, required: true
  attr :titles, :map, required: true, doc: "the sources' titles, which addresses name"
  attr :selected, :any, required: true, doc: "the id of the entry shown beside the list"

  def list_row(%{row: {:heading, _key, label}} = assigns) do
    assigns = assign(assigns, :label, label)

    ~H"""
    <h2
      id={row_id(@row)}
      data-group
      class="border-b border-line bg-surface px-6 pt-4 pb-1.5 text-meta font-semibold tracking-wider text-muted uppercase sm:px-12 lg:sticky lg:top-(--list-head) lg:z-[5] lg:px-4"
    >
      {@label}
    </h2>
    """
  end

  def list_row(%{row: {:entry, entry}} = assigns) do
    assigns = assign(assigns, :entry, entry)

    ~H"""
    <.entry_row
      id={row_id(@row)}
      entry={@entry}
      to={SikioWeb.LibraryPaths.library_path(@filters, @entry, @titles)}
      selected={@selected == @entry.id}
      source_shown={@filters["source"] == ""}
      movable={@filters["status"] == "queue"}
    />
    """
  end

  attr :filters, :map, required: true

  # The empty state names what the list would contain and gives no instructions.
  def list_empty(assigns) do
    {title, why} = nothing(assigns.filters)
    assigns = assign(assigns, title: title, why: why)

    ~H"""
    <section
      id="list-empty"
      role="status"
      class="border-t border-line px-6 py-12 text-center sm:px-12 lg:border-t-0 lg:px-4"
    >
      <p class="font-semibold text-ink">{@title}</p>
      <p :if={@why} class="mt-1 text-label text-muted">{@why}</p>
    </section>
    """
  end

  # Returns the empty state's title and an optional explanation.
  defp nothing(%{"q" => q}) when q not in [nil, ""],
    do: {gettext("Nothing matches “%{query}”.", query: q), nil}

  defp nothing(%{"status" => "inbox"}),
    do: {gettext("Nothing new."), gettext("You’re all caught up.")}

  defp nothing(%{"status" => "queue"}),
    do:
      {gettext("Nothing in the queue."),
       gettext("What you play or queue waits here, in your order.")}

  defp nothing(%{"status" => "heard"}), do: {gettext("Nothing heard yet."), nil}

  defp nothing(_filters),
    do: {gettext("No items yet."), gettext("New items arrive as your sources publish them.")}

  # A list row: picture, source, title and playback status.
  # The picture is proxied through Sikio's host. It tries the item's image, the source artwork,
  # then a kind icon, so every row has the same shape.
  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :to, :string, required: true
  attr :selected, :boolean, required: true
  attr :source_shown, :boolean, default: true, doc: "false within the source's own list"
  attr :movable, :boolean, default: false, doc: "whether the row carries a handle, in the queue"

  def entry_row(assigns) do
    assigns =
      assign(assigns, status: status(assigns.entry), runtime: runtime(length_of(assigns.entry)))

    ~H"""
    <article
      id={@id}
      data-status={@status}
      class={[
        "border-b border-line last:border-b-0 lg:last:border-b",
        @movable && "flex items-stretch",
        @selected && "bg-selection"
      ]}
    >
      <.link
        id={"play-#{@entry.id}"}
        patch={@to}
        aria-current={@selected && "true"}
        class={[
          "flex min-w-0 grow gap-3 px-6 py-3 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent sm:px-12 lg:px-4",
          @movable && "pr-0 sm:pr-0 lg:pr-0",
          !@selected && "hover:bg-ground/50"
        ]}
      >
        <span class="relative h-21 w-28 shrink-0 overflow-hidden rounded-lg bg-line">
          <img
            src={Pictures.path(Sikio.Pictures.candidates(@entry), kind_mark(@entry))}
            alt=""
            loading="lazy"
            class="size-full object-cover"
          />
          <span
            :if={@runtime}
            id={"runtime-#{@entry.id}"}
            class="absolute right-1 bottom-2 rounded bg-black/75 px-1 font-mono text-[11px] font-medium text-white"
          >
            {@runtime}
          </span>
          <.progress :if={@status == :in_progress} entry={@entry} />
        </span>
        <span class="flex min-w-0 grow flex-col gap-1">
          <span :if={@source_shown} data-source class="truncate text-meta font-semibold text-muted">
            {source_name(@entry)}
          </span>
          <span class={[
            "mb-auto line-clamp-2 text-body",
            @status in [:heard, :archived] && "text-muted",
            @status not in [:heard, :archived] && "font-semibold text-ink"
          ]}>
            {@entry.title}
          </span>
          <span class="flex flex-wrap items-center gap-x-1.5 text-meta text-muted">
            <.status_mark entry={@entry} status={@status} />
            <span aria-hidden="true">·</span>
            <span>{medium_label(@entry)}</span>
            <span :if={@entry.published_at} aria-hidden="true">·</span>
            <span :if={@entry.published_at} class="font-mono tracking-tighter">
              {short_date(@entry.published_at)}
            </span>
          </span>
        </span>
      </.link>
      <%!-- Drag handle. Arrow keys move the row one position; see assets/js/queue_sort.mjs. --%>
      <button
        :if={@movable}
        id={"move-#{@entry.id}"}
        type="button"
        data-move={@entry.id}
        aria-label={gettext("Move %{title} in the queue", title: @entry.title)}
        title={gettext("Drag, or use the arrow keys")}
        class="flex w-11 shrink-0 cursor-grab touch-none items-center justify-center text-muted hover:text-ink focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-accent sm:w-14"
      >
        <Lucideicons.grip_vertical aria-hidden="true" class="size-5" />
      </button>
    </article>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  # A `role="group"` of segment links. Its `aria-label` names the group for screen readers.
  def segments(assigns) do
    ~H"""
    <div role="group" aria-label={@label} class="flex flex-wrap gap-2">
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :id, :string, required: true
  attr :to, :string, required: true
  attr :active, :boolean, required: true
  slot :inner_block, required: true

  def segment(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@to}
      aria-current={@active && "true"}
      class="inline-flex min-h-8 items-center rounded-full border border-line bg-surface px-3 text-label text-ink hover:bg-ground aria-[current=true]:border-transparent aria-[current=true]:bg-accent aria-[current=true]:font-semibold aria-[current=true]:text-on-accent"
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :entry, :map, required: true
  attr :again, :boolean, required: true, doc: "the item was heard and goes in once more"

  # Menu that adds the item at the start or the end of the queue.
  def queue_menu(assigns) do
    ~H"""
    <.item_menu
      id="queue-menu"
      label={if @again, do: gettext("Queue again"), else: gettext("Add to queue")}
      named
    >
      <:icon><Lucideicons.list_plus aria-hidden="true" class="size-4.5" /></:icon>
      <.menu_item id="queue-first" push={{"queue", %{id: @entry.id, at: "first"}}} menu="queue-menu">
        <:icon><Lucideicons.list_start aria-hidden="true" class="size-4" /></:icon>
        {gettext("Play next")}
      </.menu_item>
      <.menu_item id="queue-last" push={{"queue", %{id: @entry.id, at: "last"}}} menu="queue-menu">
        <:icon><Lucideicons.list_end aria-hidden="true" class="size-4" /></:icon>
        {gettext("Play last")}
      </.menu_item>
    </.item_menu>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true

  attr :named, :boolean,
    default: false,
    doc: "shows its label beside a chevron, as the actions do"

  slot :icon
  slot :inner_block, required: true

  # A `<details>` menu in the card header. The card re-renders during playback, so
  # `JS.ignore_attributes` keeps the `open` attribute. A click outside or Escape closes it.
  def item_menu(assigns) do
    ~H"""
    <details
      id={@id}
      class="relative"
      phx-mounted={JS.ignore_attributes(["open"])}
      phx-click-away={JS.remove_attribute("open", to: "##{@id}")}
      phx-window-keydown={JS.remove_attribute("open", to: "##{@id}")}
      phx-key="Escape"
    >
      <summary
        aria-label={!@named && @label}
        title={!@named && @label}
        class={[
          "flex h-9 cursor-pointer list-none items-center gap-1.5 rounded-full text-label font-medium text-muted hover:bg-ground hover:text-ink focus-visible:outline-2 focus-visible:outline-accent [[open]>&]:bg-ground [[open]>&]:text-ink",
          if(@named, do: "px-3", else: "w-9 justify-center")
        ]}
      >
        <%= if @named do %>
          {render_slot(@icon)}
          <span class="@max-2xl:sr-only">{@label}</span>
          <Lucideicons.chevron_down aria-hidden="true" class="size-3.5 @max-2xl:hidden" />
        <% else %>
          <Lucideicons.ellipsis aria-hidden="true" class="size-4.5" />
        <% end %>
      </summary>
      <%!-- z-50 keeps the menu above the dock's player, which covers the slot at z-40. --%>
      <div class="absolute top-full right-0 z-50 mt-1 flex w-max min-w-48 flex-col rounded-control border border-line bg-surface p-1 shadow-lg">
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  attr :id, :string, required: true
  attr :menu, :string, required: true, doc: "the menu it closes"
  attr :push, :any, default: nil, doc: "the event and its values"
  attr :href, :string, default: nil, doc: "an address it opens in a new tab instead"
  slot :icon, required: true
  slot :inner_block, required: true

  def menu_item(assigns) do
    assigns =
      assign(
        assigns,
        :class,
        "flex min-h-11 w-full cursor-pointer items-center gap-2.5 rounded-control px-3 text-left text-label text-ink hover:bg-ground sm:min-h-9"
      )

    ~H"""
    <a
      :if={@href}
      id={@id}
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      phx-click={JS.remove_attribute("open", to: "##{@menu}")}
      class={@class}
    >
      {render_slot(@icon)}{render_slot(@inner_block)}
    </a>
    <button
      :if={!@href}
      id={@id}
      type="button"
      phx-click={
        JS.push(elem(@push, 0), value: elem(@push, 1)) |> JS.remove_attribute("open", to: "##{@menu}")
      }
      class={@class}
    >
      {render_slot(@icon)}{render_slot(@inner_block)}
    </button>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, default: nil
  attr :rest, :global, include: ~w(target rel)
  slot :icon, required: true

  # A card header action with icon and label, a link when `href` is set.
  # Below the `@2xl` container width, which fits three labels and the meta line, labels are
  # `sr-only`. A container query is used because the card width depends on the columns.
  def card_action(assigns) do
    assigns =
      assign(
        assigns,
        :class,
        "inline-flex h-9 items-center gap-1.5 rounded-full px-3 text-label font-medium text-muted hover:bg-ground hover:text-ink"
      )

    ~H"""
    <a :if={@href} id={@id} href={@href} class={@class} {@rest}>
      {render_slot(@icon)}
      <span class="@max-2xl:sr-only">{@label}</span>
    </a>
    <button :if={!@href} id={@id} type="button" class={@class} {@rest}>
      {render_slot(@icon)}
      <span class="@max-2xl:sr-only">{@label}</span>
    </button>
    """
  end

  attr :entry, :map, required: true
  attr :status, :atom, required: true

  # Playback status for the row and the detail: new, time left, heard or archived.
  def status_mark(assigns) do
    ~H"""
    <span :if={@status == :in_progress} class="font-mono font-medium text-signal-strong">
      {time_left(@entry)}
    </span>
    <span :if={@status != :in_progress} class="inline-flex items-center gap-1.5">
      <span :if={@status == :new} aria-hidden="true" class="size-1.5 rounded-full bg-signal"></span>
      <Lucideicons.check :if={@status == :heard} aria-hidden="true" class="size-3.5" />
      <Lucideicons.archive :if={@status == :archived} aria-hidden="true" class="size-3.5" />
      {status_label(@entry)}
    </span>
    """
  end

  # The cue's position before playback, matching where the dock player would resume.
  defp cue_position(%{playback: nil}), do: 0
  defp cue_position(%{playback: playback}), do: Playback.resume_position(playback)

  # Progress bar along the bottom of the picture, shown only when the length is known.
  attr :entry, :map, required: true

  def progress(assigns) do
    assigns = assign(assigns, :percent, percent(assigns.entry))

    ~H"""
    <span
      :if={@percent}
      role="progressbar"
      aria-label={gettext("Progress")}
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={@percent}
      class="absolute inset-x-0 bottom-0 h-1 bg-black/40"
    >
      <span class="block h-full bg-signal" style={"width: #{@percent}%"}></span>
    </span>
    """
  end

  defp percent(%{playback: playback} = entry) do
    duration = length_of(entry)
    if duration && duration > 0, do: min(round(playback.position / duration * 100), 100)
  end

  @doc "Returns an entry's length: the duration the player measured, else the feed's."
  # YouTube feeds have no duration, so a video has one only after this account played it.
  def length_of(%{playback: %{duration: duration}}) when is_number(duration), do: duration
  def length_of(entry), do: entry.duration

  # Remaining time in whole minutes, at least 1. Without a length, or past it, the status label.
  defp time_left(%{playback: playback} = entry) do
    duration = length_of(entry)

    if duration && duration > playback.position,
      do:
        gettext("%{minutes} min left",
          minutes: max(round((duration - playback.position) / 60), 1)
        ),
      else: status_label(entry)
  end

  # The selected item's detail. Playback runs in the dock, started by a `sikio:play` browser
  # event, so the media element is never moved.
  attr :chapters, :list, required: true
  attr :entry, :map, required: true

  # Chapter list. A click dispatches `sikio:play` with the chapter's position, which starts or
  # seeks the player. The current chapter has `aria-current`.
  def chapters(assigns) do
    assigns = assign(assigns, :current, current_chapter(assigns.chapters, assigns.entry))

    ~H"""
    <nav id="item-chapters" aria-label={gettext("Chapters")} class="rounded-xl bg-ground p-2">
      <ol class="flex flex-col">
        <li :for={chapter <- @chapters}>
          <button
            type="button"
            phx-click={JS.dispatch("sikio:play", detail: %{id: @entry.id, position: chapter.at})}
            aria-current={chapter == @current && "true"}
            class="flex w-full items-baseline gap-3 rounded-lg px-2 py-1.5 text-left text-label hover:bg-surface aria-[current]:bg-surface aria-[current]:font-semibold aria-[current]:text-accent"
          >
            <span class="w-14 shrink-0 font-mono text-meta text-muted tabular-nums">
              {runtime(chapter.at) || "0:00"}
            </span>
            <span>{chapter.title}</span>
          </button>
        </li>
      </ol>
    </nav>
    """
  end

  # The last chapter at or before the position while the item is in progress, else nil.
  defp current_chapter(chapters, %{playback: %{status: :in_progress, position: position}}) do
    chapters |> Enum.filter(&(&1.at <= position)) |> List.last()
  end

  defp current_chapter(_chapters, _entry), do: nil

  attr :entry, :map, required: true
  attr :notes, :any, required: true, doc: "the filtered notes, or nil"
  attr :chapters, :list, required: true, doc: "the chapters the notes listed"

  def detail(assigns) do
    entry = assigns.entry

    assigns =
      assign(assigns,
        status: status(entry),
        queued: match?(%{playback: %{queue_rank: rank}} when not is_nil(rank), entry),
        runtime: runtime(length_of(entry)),
        original: original(entry)
      )

    ~H"""
    <%!-- From lg the detail is a card; below lg it has no card styling.
    The player slot spans the full width in both. --%>
    <article class="@container flex flex-col gap-4 lg:rounded-xl lg:bg-surface lg:p-6 lg:ring-1 lg:ring-line">
      <div class="flex items-start gap-3">
        <%!-- The source icon, proxied as in the sidebar, or the source's initial. --%>
        <span
          id="item-source-mark"
          aria-hidden="true"
          class="flex size-8 shrink-0 items-center justify-center overflow-hidden rounded-full bg-accent/15 text-meta font-semibold text-accent"
        >
          <img
            :if={@entry.feed.icon_url}
            src={Pictures.path([@entry.feed.icon_url], kind_mark(@entry.feed))}
            alt=""
            class="size-full object-cover"
          />
          <span :if={!@entry.feed.icon_url}>{initial(source_name(@entry))}</span>
        </span>
        <div class="flex min-w-0 grow flex-col">
          <p class="truncate text-label font-semibold text-ink">{source_name(@entry)}</p>
          <p
            id="playback-status"
            aria-live="polite"
            class="meta-dots flex flex-wrap items-center text-meta text-muted"
          >
            <%!-- The medium label links to the original, like the menu's last item. --%>
            <span :if={!@original}>{medium_label(@entry)}</span>
            <span :if={@original}>
              <a
                href={elem(@original, 0)}
                target="_blank"
                rel="noopener noreferrer"
                class="underline decoration-signal decoration-[1.5px] underline-offset-3 [text-decoration-skip-ink:none] hover:text-ink hover:decoration-current"
              >
                {medium_label(@entry)}
              </a>
            </span>
            <span :if={@entry.published_at} class="font-mono tracking-tighter">
              {date(@entry.published_at)}
            </span>
            <span :if={@runtime} class="font-mono tracking-tighter">{@runtime}</span>
            <span><.status_mark entry={@entry} status={@status} /></span>
            <%!-- Icon only, so starting or queueing an item does not wrap the line and shift the card. --%>
            <span :if={@queued} title={gettext("In the queue")}>
              <Lucideicons.list_ordered aria-hidden="true" class="size-3.5" />
              <span class="sr-only">{gettext("In the queue")}</span>
            </span>
          </p>
        </div>
        <%!-- The header shows the next step for the item; the menu holds the other actions. --%>
        <div id="item-actions" class="-mt-1 -mr-2 flex shrink-0 items-center gap-1">
          <.queue_menu :if={!@queued} entry={@entry} again={@status == :heard} />
          <.card_action
            :if={@queued and @status != :heard}
            id="mark-completed"
            label={mark_done_label(@entry)}
            phx-click="mark"
            phx-value-id={@entry.id}
            phx-value-status="heard"
          >
            <:icon><Lucideicons.check aria-hidden="true" class="size-4.5" /></:icon>
          </.card_action>
          <.card_action
            :if={!@queued and @status in [:new, :in_progress]}
            id="archive"
            label={gettext("Archive")}
            phx-click="mark"
            phx-value-id={@entry.id}
            phx-value-status="archived"
          >
            <:icon><Lucideicons.archive aria-hidden="true" class="size-4.5" /></:icon>
          </.card_action>
          <.item_menu id="item-more" label={gettext("More actions")}>
            <.menu_item
              :if={@queued}
              id="dequeue"
              push={{"dequeue", %{id: @entry.id}}}
              menu="item-more"
            >
              <:icon><Lucideicons.list_x aria-hidden="true" class="size-4" /></:icon>
              {gettext("Remove from the queue")}
            </.menu_item>
            <.menu_item
              :if={!@queued and @status != :heard}
              id="mark-completed"
              push={{"mark", %{id: @entry.id, status: "heard"}}}
              menu="item-more"
            >
              <:icon><Lucideicons.check aria-hidden="true" class="size-4" /></:icon>
              {mark_done_label(@entry)}
            </.menu_item>
            <.menu_item
              :if={@queued and @status != :heard}
              id="archive"
              push={{"mark", %{id: @entry.id, status: "archived"}}}
              menu="item-more"
            >
              <:icon><Lucideicons.archive aria-hidden="true" class="size-4" /></:icon>
              {gettext("Archive")}
            </.menu_item>
            <.menu_item
              :if={@status in [:heard, :archived]}
              id="mark-new"
              push={{"mark", %{id: @entry.id, status: "new"}}}
              menu="item-more"
            >
              <:icon><Lucideicons.inbox aria-hidden="true" class="size-4" /></:icon>
              {if @status == :heard,
                do: mark_new_label(@entry),
                else: gettext("Back to the inbox")}
            </.menu_item>
            <.menu_item
              :if={@original}
              id="open-original"
              href={elem(@original, 0)}
              menu="item-more"
            >
              <:icon><Lucideicons.external_link aria-hidden="true" class="size-4" /></:icon>
              {elem(@original, 1)}
            </.menu_item>
            <%!-- Only a singly saved item leaves the library; a followed one stays with its source. --%>
            <.menu_item
              :if={@entry.followed == false}
              id="remove-entry"
              push={{"remove_entry", %{id: @entry.id}}}
              menu="item-more"
            >
              <:icon><Lucideicons.trash_2 aria-hidden="true" class="size-4" /></:icon>
              {gettext("Remove from library")}
            </.menu_item>
          </.item_menu>
        </div>
      </div>
      <%!-- Player slot. The dock positions the active player over it. Before playback it shows
      a preview and loads no third-party resources. See assets/js/dock_place.mjs. --%>
      <div
        id="player-slot"
        phx-mounted={JS.ignore_attributes(["style", "data-pinned"])}
        class="-mx-6 sm:-mx-12 lg:-mx-6"
      >
        <button
          :if={video?(@entry)}
          id="start-playback"
          type="button"
          phx-click={JS.dispatch("sikio:play", detail: %{id: @entry.id})}
          class="group block w-full text-left focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
        >
          <span class="relative block aspect-video w-full overflow-hidden bg-line">
            <img
              src={Pictures.path(Sikio.Pictures.candidates(@entry), kind_mark(@entry))}
              alt=""
              class="size-full object-cover"
            />
            <span class="absolute inset-0 flex items-center justify-center bg-black/10">
              <span class="flex size-16 items-center justify-center rounded-full bg-accent text-on-accent shadow-lg transition group-hover:scale-105">
                <Lucideicons.play aria-hidden="true" class="size-7 fill-current" />
              </span>
            </span>
            <span class="sr-only">{play_label(@entry)}</span>
          </span>
        </button>
        <%!-- An episode renders the audio controls inline. No media loads before first use; see
        assets/js/audio_cue.mjs. --%>
        <.audio_face
          :if={!video?(@entry)}
          id="audio-cue"
          phx-hook="AudioCue"
          cue={@entry}
          length={length_of(@entry)}
          position={cue_position(@entry)}
          chapters={@chapters}
          data-entry-id={@entry.id}
          data-position-of={
            gettext("%{position} of %{duration}", position: "{position}", duration: "{duration}")
          }
        />
      </div>
      <%!-- Title and notes follow the player in one centered column of at most 80ch.
      `w-full` keeps that width when the text is shorter. --%>
      <section class="mx-auto flex w-full max-w-[80ch] flex-col gap-3 pt-2">
        <h2 data-large-title class="text-[26px] leading-tight font-semibold">{@entry.title}</h2>
        <.chapters :if={@chapters != []} chapters={@chapters} entry={@entry} />
        <div class="flex flex-col gap-3 border-t border-line pt-4">
          <div :if={@notes} id="item-notes" class="notes text-body text-ink">
            {@notes}
          </div>
          <p :if={!@notes} id="item-no-notes" class="text-muted">
            {gettext("The publisher sent no notes for this item.")}
          </p>
        </div>
      </section>
    </article>
    """
  end
end
