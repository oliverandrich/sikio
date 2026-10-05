# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SubscriptionsLive do
  @moduledoc """
  Lists the account's subscriptions to pause, resume or leave. The collection is imported or
  exported as OPML. `SikioWeb.AddSourceLive` adds a source.
  """
  use SikioWeb, :live_view

  import SikioWeb.MediaComponents, only: [refresh_problem: 1, source_label: 1]

  alias Sikio.Library

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

  def handle_event("unsubscribe", %{"id" => id}, socket) do
    case Library.unsubscribe(socket.assigns.current_account, id) do
      {:ok, _} -> {:noreply, load_subscriptions(socket)}
      _ -> {:noreply, put_flash(socket, :error, gettext("Subscription not found."))}
    end
  end

  defp load_subscriptions(socket) do
    subscriptions = Library.subscriptions(socket.assigns.current_account)

    socket
    |> assign(subscription_count: length(subscriptions))
    |> stream(:subscriptions, subscriptions, reset: true)
  end

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
        <div id="subscriptions" phx-update="stream" class="space-y-3">
          <article
            :for={{dom_id, subscription} <- @streams.subscriptions}
            id={dom_id}
            class="flex flex-wrap items-center justify-between gap-5 rounded-control border border-line bg-surface p-6"
          >
            <div class="min-w-0 flex-1">
              <p class="text-meta font-medium text-muted">
                {source_label(subscription.feed)} · {if subscription.paused,
                  do: gettext("Polling paused"),
                  else: gettext("Active")}
              </p>
              <h3 class="mt-1 text-lg font-semibold">
                {SikioWeb.MediaComponents.source_name(subscription)}
              </h3>
              <p class="mt-2 text-meta break-all text-muted">
                {subscription.feed.url}
              </p>
              <p
                :if={subscription.feed.last_error}
                class="mt-2 text-label text-warning"
              >
                {refresh_problem(subscription.feed.last_error)}
                {gettext("Imported items are safe.")}
              </p>
            </div>
            <div class="flex gap-5 text-label">
              <button
                phx-click="pause"
                phx-value-id={subscription.id}
                phx-value-paused={to_string(!subscription.paused)}
                class="min-h-11 cursor-pointer text-link"
              >{if subscription.paused, do: gettext("Resume"), else: gettext("Pause polling")}</button>
              <button
                phx-click="unsubscribe"
                phx-value-id={subscription.id}
                class="min-h-11 text-muted"
              >{gettext("Unsubscribe")}</button>
            </div>
          </article>
        </div>
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
