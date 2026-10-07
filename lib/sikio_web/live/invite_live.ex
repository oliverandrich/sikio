# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InviteLive do
  @moduledoc """
  The page for an invitation link.

  It shows the invitation's identifier and has no field to change it.
  `Ithibati.Identity.Invitations.accept/2` requires the new account to carry that identifier.
  An editable field could only produce a refusal.
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
      <p :if={@invitation} class="mb-6 text-center text-label text-muted">
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
        class="rounded-control border p-4 border-danger bg-danger-surface text-danger mt-6"
      >
        <span>
          {gettext("This invitation has been used already, or it has expired. Ask for a new link.")}
        </span>
      </div>

      <div
        :if={@error}
        role="alert"
        class="rounded-control border p-4 border-danger bg-danger-surface text-danger mt-6"
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
