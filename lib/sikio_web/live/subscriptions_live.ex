# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SubscriptionsLive do
  @moduledoc """
  Lists the account's subscriptions to pause, resume, edit or leave. The collection is imported or
  exported as OPML. `SikioWeb.AddSourceLive` adds a source.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents,
    only: [kind_mark: 1, initial: 1, refresh_problem: 1, source_label: 1, source_name: 1]

  alias Sikio.Library
  alias SikioWeb.Pictures
  alias SikioWeb.Sidebar
  alias SikioWeb.SubscriptionSettings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Subscriptions"))
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
  def handle_info({SubscriptionSettings, :not_found}, socket),
    do: {:noreply, put_flash(socket, :error, gettext("Subscription not found."))}

  # Saved or left, the list and the sidebar show it.
  def handle_info({SubscriptionSettings, _done}, socket),
    do: {:noreply, socket |> load_subscriptions() |> Sidebar.refresh()}

  defp load_subscriptions(socket) do
    subscriptions = Library.subscriptions(socket.assigns.current_account)

    socket
    |> assign(subscription_count: length(subscriptions))
    |> stream(:subscriptions, subscriptions, reset: true)
  end

  # An icon button in a row. Leaving turns red under the pointer, everything else ink.
  defp row_action(hover \\ "hover:text-ink"),
    do: [
      "flex size-11 items-center justify-center rounded-full text-muted hover:bg-ground focus-visible:outline-2 focus-visible:outline-accent sm:size-9",
      hover
    ]

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
              <img
                :if={subscription.feed.icon_url}
                src={Pictures.path([subscription.feed.icon_url], kind_mark(subscription.feed))}
                alt=""
                class="size-full object-cover"
              />
              <span :if={!subscription.feed.icon_url}>{initial(source_name(subscription))}</span>
            </span>
            <div class="min-w-0 flex-1">
              <%!-- The address follows the name. Both are cut to fit; the full address is its title. --%>
              <p class="flex flex-wrap items-baseline gap-x-2 sm:flex-nowrap">
                <.link
                  navigate={Sidebar.source_path(subscription)}
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
                <span>{delivery_label(subscription.delivery)}</span>
              </p>
              <p :if={subscription.feed.last_error} class="mt-1 text-label text-warning">
                {refresh_problem(subscription.feed.last_error)}
                {gettext("Imported items are safe.")}
              </p>
            </div>
            <%!-- On a phone the actions sit below the text, under the name. --%>
            <div class="-ml-2.5 flex w-full shrink-0 items-center gap-1 pl-12 sm:ml-0 sm:w-auto sm:pl-0">
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
        <p class="mt-5 text-meta text-muted">
          {gettext(
            "Active sources refresh every 15 minutes. A shared feed may still update for other subscribers while your polling is paused."
          )}
        </p>
      </section>
    </Layouts.member>
    """
  end
end
