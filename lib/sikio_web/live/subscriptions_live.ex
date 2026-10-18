# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SubscriptionsLive do
  @moduledoc """
  Lists the account's subscriptions with refresh, pause, resume, edit and unsubscribe actions.
  Links to OPML import and export. `SikioWeb.AddSourceLive` adds a source.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents,
    only: [initial: 1, refresh_problem: 1, source_label: 1, source_name: 1, with_source_icon: 1]

  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.Hub
  alias Sikio.Feeds.Refresh
  alias Sikio.Library
  alias SikioWeb.LibraryPaths
  alias SikioWeb.Sidebar
  alias SikioWeb.SubscriptionSettings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     # Feed ids whose queued refresh has not reported yet. A reload forgets them.
     |> assign(page_title: gettext("Subscriptions"), refreshing: MapSet.new())
     |> stream_configure(:subscriptions, dom_id: &"subscription-#{&1.id}")
     |> load_subscriptions()}
  end

  @impl true
  def handle_event("pause", %{"id" => id, "paused" => paused}, socket) do
    case Library.pause(socket.assigns.current_account, id, paused == "true") do
      {:ok, _} -> {:noreply, load_subscriptions(socket)}
      _ -> {:noreply, put_flash(socket, :error, gettext("Subscription not found."))}
    end
  end

  def handle_event("refresh", %{"id" => id}, socket) do
    case Library.refresh(socket.assigns.current_account, id) do
      {:ok, feed_id} ->
        {:noreply, socket |> await_checks([feed_id]) |> load_subscriptions()}

      {:error, :recent} ->
        {:noreply,
         put_flash(socket, :info, gettext("This source was checked less than a minute ago."))}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, gettext("Subscription not found."))}
    end
  end

  def handle_event("refresh_all", _params, socket) do
    case Library.refresh_all(socket.assigns.current_account) do
      [] ->
        message = gettext("Every active source was checked less than a minute ago.")
        {:noreply, put_flash(socket, :info, message)}

      feed_ids ->
        {:noreply, socket |> await_checks(feed_ids) |> load_subscriptions()}
    end
  end

  def handle_event(action, %{"id" => id}, socket) when action in ["edit", "leave"] do
    subscription =
      Enum.find(socket.assigns.sidebar.sources, &(to_string(&1.id) == id))

    if subscription do
      open = if action == "edit", do: :edit, else: :leave

      send_update(SubscriptionSettings,
        id: "subscription-settings",
        open: {open, subscription, "#{action}-subscription-#{id}"}
      )
    end

    {:noreply, socket}
  end

  @impl true
  # Arrives only for feeds this page queued, see `await_checks/2`. Only that row changes.
  def handle_info({:feed_checked, feed_id}, socket) do
    Refresh.unsubscribe(feed_id)
    socket = update(socket, :refreshing, &MapSet.delete(&1, feed_id))

    case Library.subscription_to(socket.assigns.current_account, feed_id) do
      nil -> {:noreply, load_subscriptions(socket)}
      subscription -> {:noreply, stream_insert(socket, :subscriptions, subscription)}
    end
  end

  def handle_info({SubscriptionSettings, :not_found}, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Subscription not found."))}

  def handle_info({SubscriptionSettings, {:refused, message}}, socket),
    do: {:noreply, put_flash(socket, :error, message)}

  def handle_info({SubscriptionSettings, {:removed, message}}, socket),
    do:
      {:noreply, socket |> put_flash(:info, message) |> load_subscriptions() |> Sidebar.refresh()}

  # After a save or unsubscribe, reloads the list and refreshes the sidebar.
  def handle_info({SubscriptionSettings, _done}, socket),
    do: {:noreply, socket |> load_subscriptions() |> Sidebar.refresh()}

  defp load_subscriptions(socket) do
    subscriptions = Library.subscriptions(socket.assigns.current_account)

    socket
    |> assign(
      subscription_count: length(subscriptions),
      any_active: Enum.any?(subscriptions, &(!&1.paused)),
      live: Hub.live(Enum.map(subscriptions, & &1.feed_id))
    )
    |> stream(:subscriptions, subscriptions, reset: true)
  end

  # Classes for a row's icon button. Unsubscribe hovers red, the others ink.
  defp row_action(hover \\ "hover:text-ink"),
    do: [
      "flex size-11 items-center justify-center rounded-full text-muted hover:bg-ground focus-visible:outline-2 focus-visible:outline-accent sm:size-9",
      hover
    ]

  # Follows each feed's refresh topic once, so a second click delivers one result, not two.
  defp await_checks(socket, feed_ids) do
    new = Enum.reject(feed_ids, &MapSet.member?(socket.assigns.refreshing, &1))
    Enum.each(new, &Refresh.subscribe/1)
    update(socket, :refreshing, &MapSet.union(&1, MapSet.new(new)))
  end

  defp polling_label(%{paused: true}), do: gettext("Resume polling")
  defp polling_label(_subscription), do: gettext("Pause polling")

  defp delivery_label(:inbox), do: gettext("To the inbox")
  defp delivery_label(:queue), do: gettext("To the end of the queue")
  defp delivery_label(:skip), do: gettext("Straight to the archive")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      section={:subscriptions}
      title={gettext("Subscriptions")}
      back={%{to: ~p"/library", label: gettext("Library")}}
    >
      <.header>
        {gettext("Your subscriptions")}
        <:subtitle>{ngettext("%{count} source", "%{count} sources", @subscription_count)}</:subtitle>
      </.header>
      <div class="mt-6 flex flex-wrap gap-5 text-label font-semibold">
        <.link
          id="opml-import-link"
          navigate={~p"/subscriptions/import"}
          class="inline-flex min-h-11 items-center text-link"
        >{gettext("Import OPML")}</.link>
        <.link
          id="opml-export-link"
          href={~p"/subscriptions.opml"}
          class="inline-flex min-h-11 items-center gap-1 text-link"
        >
          {gettext("Export OPML")}
          <Lucideicons.download aria-hidden="true" class="size-4" />
        </.link>
        <.link
          id="library-transfer-link"
          navigate={~p"/subscriptions/library"}
          class="inline-flex min-h-11 items-center text-link"
        >{gettext("Move your library")}</.link>
        <button
          :if={@any_active}
          id="refresh-all-subscriptions"
          type="button"
          phx-click="refresh_all"
          class="inline-flex min-h-11 items-center gap-1 text-link"
        >
          {gettext("Refresh all")}
          <Lucideicons.rotate_cw aria-hidden="true" class="size-4" />
        </button>
      </div>
      <section class="mt-8">
        <p
          :if={@subscription_count == 0}
          id="subscriptions-empty"
          class="rounded-control border border-dashed border-line p-8 text-muted"
        >
          {gettext("Your collection starts with one good source.")}
        </p>
        <div
          id="subscriptions"
          phx-update="stream"
          class="divide-y divide-line overflow-hidden rounded-xl bg-surface ring-1 ring-line"
        >
          <article
            :for={{dom_id, subscription} <- @streams.subscriptions}
            id={dom_id}
            class="flex flex-wrap items-center gap-x-3 px-4 py-3 sm:flex-nowrap"
          >
            <span
              aria-hidden="true"
              class="flex size-9 shrink-0 items-center justify-center overflow-hidden rounded-full bg-accent/15 text-meta font-semibold text-accent"
            >
              <.with_source_icon :let={icon} source={subscription.feed}>
                <img :if={icon} src={icon} alt="" class="size-full object-cover" />
                <span :if={!icon}>{initial(source_name(subscription))}</span>
              </.with_source_icon>
            </span>
            <div class="min-w-0 flex-1">
              <%!-- The feed URL follows the name. Both truncate; `title` holds the full URL. --%>
              <p class="flex flex-wrap items-baseline gap-x-2 sm:flex-nowrap">
                <.link
                  navigate={LibraryPaths.source_path(subscription)}
                  class="truncate text-body font-semibold underline-offset-4 hover:underline"
                >
                  {source_name(subscription)}
                </.link>
                <span
                  title={subscription.feed.url}
                  class="min-w-0 truncate font-mono text-meta text-muted"
                >
                  {String.replace_prefix(subscription.feed.url, "https://", "")}
                </span>
              </p>
              <p class="meta-dots flex flex-wrap items-center text-meta text-muted">
                <span>{source_label(subscription.feed)}</span>
                <span>
                  {if subscription.paused, do: gettext("Polling paused"), else: gettext("Active")}
                </span>
                <.hub_state
                  :if={!subscription.paused and Feed.channel?(subscription.feed)}
                  live={MapSet.member?(@live, subscription.feed_id)}
                />
                <span>{delivery_label(subscription.delivery)}</span>
              </p>
              <p :if={subscription.feed.last_error} class="mt-1 text-label text-warning">
                {refresh_problem(subscription.feed.last_error)}
                {gettext("Imported items are safe.")}
              </p>
            </div>
            <%!-- Below `sm` the actions wrap to a row under the text, aligned with the name. --%>
            <div class="-ml-2.5 flex w-full shrink-0 items-center gap-1 pl-12 sm:ml-0 sm:w-auto sm:pl-0">
              <.refresh_button
                :if={!subscription.paused}
                subscription={subscription}
                refreshing={MapSet.member?(@refreshing, subscription.feed_id)}
              />
              <button
                type="button"
                phx-click="pause"
                phx-value-id={subscription.id}
                phx-value-paused={to_string(!subscription.paused)}
                aria-label={polling_label(subscription)}
                title={polling_label(subscription)}
                class={row_action()}
              >
                <Lucideicons.refresh_cw :if={subscription.paused} aria-hidden="true" class="size-4" />
                <Lucideicons.refresh_cw_off
                  :if={!subscription.paused}
                  aria-hidden="true"
                  class="size-4"
                />
              </button>
              <button
                id={"edit-subscription-#{subscription.id}"}
                type="button"
                phx-click="edit"
                phx-value-id={subscription.id}
                aria-label={gettext("Edit subscription")}
                title={gettext("Edit subscription")}
                class={row_action()}
              >
                <Lucideicons.pencil aria-hidden="true" class="size-4" />
              </button>
              <.link
                :if={subscription.feed.page_url}
                id={"open-website-#{subscription.id}"}
                href={subscription.feed.page_url}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={gettext("Open website")}
                title={gettext("Open website")}
                class={row_action()}
              >
                <Lucideicons.external_link aria-hidden="true" class="size-4" />
              </.link>
              <button
                id={"leave-subscription-#{subscription.id}"}
                type="button"
                phx-click="leave"
                phx-value-id={subscription.id}
                aria-label={gettext("Unsubscribe")}
                title={gettext("Unsubscribe")}
                class={row_action("hover:text-danger")}
              >
                <Lucideicons.unplug aria-hidden="true" class="size-4" />
              </button>
            </div>
          </article>
        </div>
        <.live_component
          module={SubscriptionSettings}
          id="subscription-settings"
          current_account={@current_account}
          tags={@sidebar.tags}
        />
        <.polling_interval minutes={Sikio.Feeds.poll_minutes()} live={MapSet.size(@live) > 0} />
      </section>
    </Layouts.member>
    """
  end

  attr :subscription, :map, required: true
  attr :refreshing, :boolean, required: true

  # Stays disabled while the queued refresh has not reported.
  defp refresh_button(assigns) do
    assigns =
      assign(
        assigns,
        :label,
        if(assigns.refreshing, do: gettext("Refreshing"), else: gettext("Refresh now"))
      )

    ~H"""
    <button
      id={"refresh-subscription-#{@subscription.id}"}
      type="button"
      phx-click="refresh"
      phx-value-id={@subscription.id}
      disabled={@refreshing}
      data-refreshing={@refreshing}
      aria-label={@label}
      title={@label}
      class={[row_action(), "disabled:cursor-progress"]}
    >
      <Lucideicons.rotate_cw
        aria-hidden="true"
        class={["size-4", @refreshing && "motion-safe:animate-spin"]}
      />
    </button>
    """
  end

  attr :live, :boolean, required: true

  # Whether Google's hub announces the channel's new videos, or Sikio asks for them at intervals.
  defp hub_state(assigns) do
    ~H"""
    <span
      :if={@live}
      data-hub="live"
      title={gettext("Google's hub announces new videos as they appear.")}
      class="text-ink"
    >
      {gettext("Live")}
    </span>
    <span
      :if={!@live}
      data-hub="polling"
      title={gettext("Sikio asks for new videos at intervals.")}
    >
      {gettext("Polling")}
    </span>
    """
  end

  @doc "Renders the maximum poll interval, in hours when it is a whole number of hours."
  attr :minutes, :integer, required: true
  attr :live, :boolean, default: false, doc: "whether a YouTube channel here is live"

  def polling_interval(assigns) do
    ~H"""
    <p id="polling-interval" class="mt-5 text-meta text-muted">
      {interval_sentence(@minutes)}
      {if @live, do: gettext("Live channels are also checked once a day.")}
      {gettext("A shared feed may still update for other subscribers while your polling is paused.")}
    </p>
    """
  end

  defp interval_sentence(minutes) when rem(minutes, 60) == 0,
    do:
      ngettext(
        "Active sources refresh at most every hour, less often when they rarely publish.",
        "Active sources refresh at most every %{count} hours, less often when they rarely publish.",
        div(minutes, 60)
      )

  defp interval_sentence(minutes),
    do:
      ngettext(
        "Active sources refresh at most every minute, less often when they rarely publish.",
        "Active sources refresh at most every %{count} minutes, less often when they rarely publish.",
        minutes
      )
end
