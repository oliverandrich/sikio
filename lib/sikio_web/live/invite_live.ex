# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InviteLive do
  @moduledoc """
  What somebody sees when they open an invitation link.

  The page shows the identifier the invitation was addressed to and does not offer to change it. That
  is not politeness: `Ithibati.Identity.Invitations.accept/2` checks that the account being created
  carries the identifier the invitation named, so a field here would only produce a refusal further
  down — and, until somebody noticed, a form that looks like it hands an invitation to whoever fills
  it in.
  """
  use SikioWeb, :live_view

  alias Ithibati.Identity.Invitations
  alias Sikio.Identity
  alias SikioWeb.CeremonyMessages

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    {:ok,
     assign(socket,
       token: token,
       invitation: Invitations.fetch(token),
       error: nil,
       email?: Identity.email?()
     )}
  end

  @impl true
  def handle_event("accept", _params, socket) do
    {:noreply, push_event(socket, "ithibati:register", %{token: socket.assigns.token})}
  end

  def handle_event("ithibati:failed", %{"error" => error} = payload, socket) do
    {:noreply, assign(socket, error: CeremonyMessages.message(error, payload["exception"]))}
  end

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title={gettext("You’re invited")}>
      <p :if={@invitation} class="mb-6 text-center text-sm text-stone-600 dark:text-stone-400">
        <span :if={not @email?}>
          {gettext("The account will be called %{username}.", username: @invitation.username)}
        </span>
        <span :if={@email?}>
          {gettext("The account will belong to %{address}.", address: @invitation.username)}
        </span>
      </p>

      <div
        :if={is_nil(@invitation)}
        role="alert"
        class="rounded-lg border p-4 border-red-300 bg-red-50 text-red-950 dark:border-red-700 dark:bg-red-950 dark:text-red-100 mt-6"
      >
        <span>
          {gettext("This invitation has been used already, or it has expired. Ask for a new link.")}
        </span>
      </div>

      <div
        :if={@error}
        role="alert"
        class="rounded-lg border p-4 border-red-300 bg-red-50 text-red-950 dark:border-red-700 dark:bg-red-950 dark:text-red-100 mt-6"
      >
        <span>{@error}</span>
      </div>

      <p :if={@invitation} class="mt-6">
        <Layouts.auth_button phx-click="accept">{gettext("Accept with a passkey")}</Layouts.auth_button>
      </p>

      <Layouts.passkey_ceremony />
    </Layouts.auth>
    """
  end
end
