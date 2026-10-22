# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ExtensionsLive do
  @moduledoc """
  Lists the browser extensions connected to the account and disconnects them.

  A disconnected extension's token stops working at its next request.
  """
  use SikioWeb, :live_view

  alias Sikio.Extensions

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: gettext("Browser extensions"))
     |> listed()}
  end

  @impl true
  def handle_event("disconnect", %{"id" => id}, socket) do
    _ = Extensions.revoke(socket.assigns.current_account, id)
    {:noreply, listed(socket)}
  end

  defp listed(socket),
    do: assign(socket, extensions: Extensions.list(socket.assigns.current_account))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      section={:account}
      title={gettext("Browser extensions")}
      back={%{to: ~p"/account/settings", label: gettext("Settings")}}
      breadcrumb
    >
      <.header>
        {gettext("Browser extensions")}
        <:subtitle>
          {gettext("Extensions connected here add sources and items to your library.")}
        </:subtitle>
      </.header>
      <p :if={@extensions == []} id="extensions-empty" class="mt-6 text-muted">
        {gettext("No browser extension is connected.")}
      </p>
      <ul
        :if={@extensions != []}
        id="extensions"
        class="mt-6 divide-y divide-line overflow-hidden rounded-xl bg-surface ring-1 ring-line"
      >
        <li :for={extension <- @extensions} class="flex items-center gap-3 px-4 py-3">
          <div class="min-w-0 flex-1">
            <p class="truncate font-semibold">{extension.label}</p>
            <p class="text-meta text-muted">
              {gettext("Connected %{date}",
                date: SikioWeb.MediaComponents.date(extension.inserted_at)
              )}
              <span :if={extension.last_used_at}>
                · {gettext("last used %{date}",
                  date: SikioWeb.MediaComponents.date(extension.last_used_at)
                )}
              </span>
            </p>
          </div>
          <button
            type="button"
            phx-click="disconnect"
            phx-value-id={extension.id}
            class="rounded-control px-3 py-1.5 text-label font-semibold text-danger hover:bg-danger-surface"
          >
            {gettext("Disconnect")}
          </button>
        </li>
      </ul>
    </Layouts.member>
    """
  end
end
