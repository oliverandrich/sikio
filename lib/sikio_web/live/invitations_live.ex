# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationsLive do
  @moduledoc """
  Creates and withdraws invitation links behind `{:require_account, to: "/login"}`.

  The gate assigns `current_account` or redirects before `mount/3` runs, so this view does not
  check it. Every member may invite; per-account invitation rules would belong here, not in
  Ithibati.
  """
  use SikioWeb, :live_view

  require Logger

  alias Sikio.AuthRateLimiter
  alias Sikio.Identity
  alias Sikio.Invitations
  alias SikioWeb.AuthRateLimit
  alias SikioWeb.CoreComponents
  alias SikioWeb.InvitationMail

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        username: "",
        link: nil,
        # The id of the invitation whose link is shown. The row stores only a token digest.
        # Withdrawing a different invitation keeps the link; the id is the only way to match it.
        link_id: nil,
        error: nil,
        email?: Identity.email?()
      )

    {:ok, listed(socket)}
  end

  defp listed(socket), do: assign(socket, pending: Invitations.pending())

  @impl true
  def handle_event("validate", %{"username" => username}, socket) do
    {:noreply, assign(socket, username: username, error: nil)}
  end

  # The rate limit runs before the changeset, so invalid attempts also count.
  # Otherwise invalid submissions would not consume the budget.
  def handle_event("invite", %{"username" => username}, socket) do
    {limit, seconds} = AuthRateLimiter.budget(:invite)
    key = AuthRateLimit.key(socket.assigns.current_account, :invite)

    case AuthRateLimiter.check(key, limit, seconds) do
      :ok -> create(socket, username)
      {:error, retry_after} -> {:noreply, assign(socket, error: too_many(retry_after))}
    end
  end

  # The id comes from the client and is not scoped to the account.
  # Every member may withdraw any unaccepted invitation, as every member may invite.
  def handle_event("withdraw", %{"id" => id}, socket) do
    {:noreply, socket |> taken_back(Invitations.get(id)) |> listed()}
  end

  defp forgotten(socket), do: assign(socket, link: nil, link_id: nil)

  defp taken_back(socket, nil),
    do: assign(socket, error: gettext("That invitation is no longer there."))

  defp taken_back(socket, invitation) do
    case Invitations.withdraw(invitation) do
      # Clears the shown link when its `link_id` matches the withdrawn invitation.
      # The withdrawn row holds only a digest, so the id is the comparison.
      {:ok, gone} ->
        socket = assign(socket, error: nil)
        if gone.id == socket.assigns.link_id, do: forgotten(socket), else: socket

      # Ithibati returns `:already_accepted` when the delete matches no unaccepted row.
      # That covers an accepted invitation and one deleted by a concurrent withdrawal.
      # The message therefore names both causes.
      {:error, :already_accepted} ->
        assign(socket,
          error:
            gettext(
              "That invitation is not waiting any more. Somebody accepted it, or took it back first."
            )
        )
    end
  end

  defp create(socket, username) do
    socket.assigns.current_account
    |> Invitations.open(%{"username" => username})
    |> case do
      # The plaintext token exists only in this return value. The row stores its SHA-256 digest.
      # The virtual `token` field is nil on any later read, so the link is shown now.
      {:ok, invitation} ->
        # Logs the inviter's id, never the invitee's username or address.
        Logger.info("invitation made", account_id: socket.assigns.current_account.id)
        link = url(~p"/invite/#{invitation.token}")

        {:noreply,
         socket
         |> listed()
         |> assign(
           link: link,
           link_id: invitation.id,
           username: "",
           error: undelivered(invitation, link)
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, error: changeset_message(changeset, socket.assigns.email?))}
    end
  end

  # Rounds the wait up to whole minutes or hours. The default window is 86,400 seconds.
  # Minutes cover configured windows under an hour, so a short wait is not shown as an hour.
  defp too_many(seconds) when seconds < 3600 do
    ngettext(
      "Too many invitations. Try again in a minute.",
      "Too many invitations. Try again in %{count} minutes.",
      div(seconds + 59, 60)
    )
  end

  defp too_many(seconds) do
    ngettext(
      "Too many invitations. Try again in an hour.",
      "Too many invitations. Try again in %{count} hours.",
      div(seconds + 3599, 3600)
    )
  end

  # The invitation is already inserted. A delivery failure shows an error and keeps it.
  defp undelivered(invitation, link) do
    case InvitationMail.deliver(invitation, link) do
      {:ok, _sent} -> nil
      {:error, _reason} -> gettext("The invitation could not be sent. Pass the link on yourself.")
    end
  end

  defp changeset_message(changeset, email?) do
    case changeset.errors do
      [{:username, error} | _rest] -> refusal(CoreComponents.translate_error(error), email?)
      _other -> gettext("That invitation could not be written.")
    end
  end

  defp refusal(message, true), do: gettext("Email address %{message}.", message: message)
  defp refusal(message, false), do: gettext("Username %{message}.", message: message)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      section={:invitations}
      title={gettext("Invitations")}
      back={%{to: ~p"/library", label: gettext("Library")}}
    >
      <.header>
        {gettext("Invitations")}
        <:subtitle>
          {gettext("Signed in as %{username}.", username: @current_account.username)}
        </:subtitle>
      </.header>

      <h2 class="mt-8 text-lg font-semibold">{gettext("Invite somebody")}</h2>

      <p :if={not @email?} class="mt-2 text-label opacity-70">
        {gettext("Choose a username for your guest, then send them their personal invitation link.")}
      </p>

      <p :if={@email?} class="mt-2 text-label opacity-70">
        {gettext("Enter your guest's email address. Their invitation link is sent there.")}
      </p>

      <form
        id="invitation-form"
        phx-change="validate"
        phx-submit="invite"
        class="mt-4 max-w-sm"
      >
        <.input
          :if={not @email?}
          name="username"
          value={@username}
          label={gettext("Their username")}
          required
          pattern={Layouts.username_pattern()}
          title={gettext("Letters, digits and underscores, up to thirty")}
          placeholder="grace_hopper"
        />
        <.input
          :if={@email?}
          type="email"
          name="username"
          value={@username}
          label={gettext("Their email address")}
          required
          placeholder="grace@example.org"
        />
        <.button variant="primary">{gettext("Create a link")}</.button>
      </form>

      <div
        :if={@error}
        role="alert"
        class="rounded-control border p-4 border-danger bg-danger-surface text-danger mt-4"
      >
        <span>{@error}</span>
      </div>

      <div
        :if={@link}
        role="status"
        class="rounded-control border p-4 border-line bg-selection text-ink mt-4"
      >
        <span>
          {gettext("Your invitation is ready. Send this link to your guest:")}
          <code class="block mt-2 break-all">{@link}</code>
        </span>
      </div>

      <h2 class="mt-10 text-lg font-semibold">{gettext("Outstanding invitations")}</h2>

      <p :if={@pending == []} class="mt-2 text-label opacity-70">
        {gettext("Nothing is waiting to be accepted.")}
      </p>

      <p :if={@pending != []} class="mt-2 text-label opacity-70">
        {gettext(
          "Anybody here can take one back. Until it is accepted, this is the only say over who joins."
        )}
      </p>

      <ul :if={@pending != []} id="pending-invitations" class="mt-4 divide-y">
        <li
          :for={invitation <- @pending}
          id={"invitation-#{invitation.id}"}
          class="flex flex-wrap items-center gap-x-4 gap-y-1 py-3"
        >
          <span class="font-medium">{invitation.username}</span>

          <span class="text-label opacity-70">
            <%= if invitation.invited_by do %>
              {gettext("Invited by %{username}", username: invitation.invited_by.username)}
            <% else %>
              {gettext("Invited by %{username}", username: gettext("Unknown"))}
            <% end %>
          </span>

          <span class="text-label opacity-70">
            {gettext("Made %{date}", date: on(invitation.inserted_at))}
          </span>

          <span class="text-label opacity-70">
            {gettext("Runs out %{date}", date: on(invitation.expires_at))}
          </span>

          <button
            type="button"
            phx-click="withdraw"
            phx-value-id={invitation.id}
            class="ml-auto text-label underline underline-offset-4"
          >
            {gettext("Take it back")}
          </button>
        </li>
      </ul>
    </Layouts.member>
    """
  end

  # Uses the application's date format, `YYYY-MM-DD`.
  defp on(at), do: Calendar.strftime(at, "%Y-%m-%d")
end
