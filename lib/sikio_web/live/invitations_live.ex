# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationsLive do
  @moduledoc """
  Manual invitation links behind `{:require_account, to: "/login"}`.

  Nothing here checks who is asking: by the time `mount/3` runs, the gate has either assigned an
  account or sent the visitor away. What an account may *do* — whether everyone can invite, or only
  some — is this application's question and would live here, not in the library.
  """
  use SikioWeb, :live_view

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
        # Which invitation the link on screen belongs to. The link is the only copy of its token
        # — the row keeps a digest — so taking some other invitation back must not take it away,
        # and there is nothing on the withdrawn row to recognise it by afterwards.
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

  # Asked before the changeset, so that an attempt which fails for any other reason still costs.
  # Otherwise the budget is a formality: type nonsense until the counter is untouched, then spend
  # the whole of it at once.
  def handle_event("invite", %{"username" => username}, socket) do
    {limit, seconds} = AuthRateLimiter.budget(:invite)
    key = AuthRateLimit.key(socket.assigns.current_account, :invite)

    case AuthRateLimiter.check(key, limit, seconds) do
      :ok -> create(socket, username)
      {:error, retry_after} -> {:noreply, assign(socket, error: too_many(retry_after))}
    end
  end

  # The id comes off the wire, and nothing here scopes it: every member may withdraw any
  # invitation that has not been accepted, which is the same rule as "every member may invite".
  # There is no "yours" to get wrong.
  def handle_event("withdraw", %{"id" => id}, socket) do
    {:noreply, socket |> taken_back(Invitations.get(id)) |> listed()}
  end

  defp forgotten(socket), do: assign(socket, link: nil, link_id: nil)

  defp taken_back(socket, nil),
    do: assign(socket, error: gettext("That invitation is no longer there."))

  defp taken_back(socket, invitation) do
    case Invitations.withdraw(invitation) do
      # The link goes too, whichever invitation it belonged to. The row that comes back holds a
      # digest and not the token, so there is nothing to compare it against — and a dead link left
      # on the screen is worse than a live one taken off it.
      {:ok, gone} ->
        socket = assign(socket, error: nil)
        if gone.id == socket.assigns.link_id, do: forgotten(socket), else: socket

      # Ithibati answers `:already_accepted` for a row that was accepted *or* is no longer there,
      # because it rechecks inside the delete and a miss cannot tell the two apart. Two members
      # pressing this at once would otherwise leave the second reading that somebody accepted an
      # invitation the first one withdrew.
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
      # The token is the only copy there will ever be: the row holds its sha256, and the virtual
      # field is empty on anything read back later. So it goes on the screen now or not at all.
      {:ok, invitation} ->
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

  # Told in whole minutes or whole hours, because the default window counts down in tens of
  # thousands of seconds and nobody reads that as a waiting time. Both, because the window is
  # configurable: an operator who sets five minutes must not be told to come back in an hour.
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

  # The invitation is already written by the time this runs, so a mail server that is down is
  # something the sender is told about rather than something that takes the invitation away.
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

      <form id="invitation-form" phx-change="validate" phx-submit="invite" class="mt-4">
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
        class="rounded-control border p-4 border-accent bg-selection text-accent mt-4"
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

  # The same spelling the rest of this application uses for a date somebody reads.
  defp on(at), do: Calendar.strftime(at, "%Y-%m-%d")
end
