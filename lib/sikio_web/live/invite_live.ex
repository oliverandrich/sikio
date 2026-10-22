# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InviteLive do
  @moduledoc """
  The page for an invitation link.

  The token is in the link's fragment, which no request sends. `assets/js/token_link.mjs`
  removes it from the address before the socket joins. The hook pushes it after the join.
  Until then the page shows a waiting line.

  An addressed invitation shows its identifier and offers no field to change it.
  `Ithibati.Identity.Invitations.accept/3` refuses an account under another identifier.
  An open invitation names nobody, so the invitee chooses the username here.
  """
  use SikioWeb, :live_view

  alias Ithibati.Identity.Invitations
  alias Sikio.Identity
  alias SikioWeb.CeremonyMessages

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       status: :waiting,
       token: nil,
       invitation: nil,
       username: "",
       error: nil,
       email?: Identity.email?()
     )}
  end

  # One token per mount. The hook pushes "" when the page was opened without a link.
  @impl true
  def handle_event(
        "invitation-token",
        %{"token" => ""},
        %{assigns: %{status: :waiting}} = socket
      ),
      do: {:noreply, assign(socket, status: :missing)}

  def handle_event(
        "invitation-token",
        %{"token" => token},
        %{assigns: %{status: :waiting}} = socket
      ) do
    invitation = Invitations.fetch(token)

    socket =
      assign(socket, token: token, invitation: invitation, status: status(invitation), error: nil)

    # The tab keeps the token for a reload. One that opens nothing is dropped there too.
    {:noreply,
     if(invitation, do: socket, else: push_event(socket, "invitation-token-forget", %{}))}
  end

  def handle_event("invitation-token", _params, socket), do: {:noreply, socket}

  def handle_event("validate", %{"username" => username}, socket) do
    {:noreply, assign(socket, username: username, error: nil)}
  end

  def handle_event("accept", params, %{assigns: %{status: status}} = socket)
      when status in [:open, :addressed] do
    identity =
      if status == :open,
        do: %{token: socket.assigns.token, username: params["username"]},
        else: %{token: socket.assigns.token}

    {:noreply, socket |> assign(error: nil) |> push_event("ithibati:register", identity)}
  end

  # Nothing is open to accept yet, or any more.
  def handle_event("accept", _params, socket), do: {:noreply, socket}

  def handle_event("ithibati:failed", %{"error" => error} = payload, socket) do
    {:noreply, assign(socket, error: CeremonyMessages.message(error, payload["exception"]))}
  end

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  defp status(nil), do: :unknown
  defp status(invitation), do: if(Invitations.open?(invitation), do: :open, else: :addressed)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title={gettext("You’re invited")}>
      <div id="invitation-link" phx-hook="TokenLink"></div>

      <p :if={@status == :waiting} class="text-center text-label text-muted">
        {gettext("Opening your invitation…")}
      </p>

      <p :if={@status == :addressed} class="mb-6 text-center text-label text-muted">
        <span :if={not @email?}>
          {gettext("The account will be called %{username}.", username: @invitation.username)}
        </span>
        <span :if={@email?}>
          {gettext("The account will belong to %{address}.", address: @invitation.username)}
        </span>
      </p>

      <div
        :if={@status == :unknown}
        role="alert"
        class="rounded-control border p-4 border-danger bg-danger-surface text-danger mt-6"
      >
        <span>
          {gettext("This invitation has been used already, or it has expired. Ask for a new link.")}
        </span>
      </div>

      <p :if={@status == :missing} class="mt-6 text-center text-label text-muted">
        {gettext("Open the link from your invitation to accept it.")}
      </p>

      <div
        :if={@error}
        role="alert"
        class="rounded-control border p-4 border-danger bg-danger-surface text-danger mt-6"
      >
        <span>{@error}</span>
      </div>

      <p :if={@status == :addressed} class="mt-6">
        <Layouts.auth_button phx-click="accept">{gettext("Accept with a passkey")}</Layouts.auth_button>
      </p>

      <form
        :if={@status == :open}
        id="invitation-accept-form"
        phx-change="validate"
        phx-submit="accept"
      >
        <p class="mb-6 text-center text-label text-muted">
          {gettext("Choose your username, then create a passkey.")}
        </p>
        <.input
          :if={not @email?}
          name="username"
          value={@username}
          label={gettext("Username")}
          autocomplete="username"
          required
          pattern={Layouts.username_pattern()}
          title={gettext("Letters, digits and underscores, up to thirty")}
          placeholder={gettext("your_username")}
        />
        <.input
          :if={@email?}
          type="email"
          name="username"
          value={@username}
          label={gettext("Email address")}
          autocomplete="email"
          required
          placeholder="you@example.org"
        />
        <Layouts.auth_button>{gettext("Accept with a passkey")}</Layouts.auth_button>
      </form>

      <Layouts.passkey_ceremony />
    </Layouts.auth>
    """
  end
end
