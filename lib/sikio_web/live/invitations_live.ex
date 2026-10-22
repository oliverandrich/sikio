# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationsLive do
  @moduledoc """
  Creates and withdraws invitation links behind `{:require_account, to: "/login"}`.

  The gate assigns `current_account` or redirects before `mount/3` runs, so this view does not
  check it. Every member may invite and take back their own invitations; an administrator takes
  back any. `Sikio.Invitations.withdraw/2` checks that, not this view.
  """
  use SikioWeb, :live_view

  require Logger

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
        note: "",
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
  def handle_event("validate", params, socket) do
    {:noreply,
     assign(socket, username: params["username"] || "", note: params["note"] || "", error: nil)}
  end

  # The rate limit runs before the changeset, so invalid attempts also count.
  # Otherwise invalid submissions would not consume the budget.
  def handle_event("invite", params, socket) do
    case AuthRateLimit.check(socket.assigns.current_account, :invite) do
      :ok -> create(socket, Map.take(params, ["username", "note"]))
      {:error, retry_after} -> {:noreply, assign(socket, error: too_many(retry_after))}
    end
  end

  # The id comes from the client and is not scoped to the account.
  def handle_event("withdraw", %{"id" => id}, socket) do
    {:noreply, socket |> taken_back(Invitations.get(id)) |> listed()}
  end

  defp forgotten(socket), do: assign(socket, link: nil, link_id: nil)

  defp taken_back(socket, nil),
    do: assign(socket, error: gettext("That invitation is no longer there."))

  defp taken_back(socket, invitation) do
    case Invitations.withdraw(socket.assigns.current_account, invitation) do
      # Clears the shown link when its `link_id` matches the withdrawn invitation.
      # The withdrawn row holds only a digest, so the id is the comparison.
      {:ok, gone} ->
        socket = assign(socket, error: nil)
        if gone.id == socket.assigns.link_id, do: forgotten(socket), else: socket

      {:error, :forbidden} ->
        assign(socket,
          error: gettext("Only the member who sent it, or an administrator, can take it back.")
        )

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

  defp create(socket, attrs) do
    socket.assigns.current_account
    |> Invitations.open(attrs)
    |> case do
      # The plaintext token exists only in this return value. The row stores its SHA-256 digest.
      # The virtual `token` field is nil on any later read, so the link is shown now.
      {:ok, invitation} ->
        # Logs the inviter's id, never the invitee's username or address.
        Logger.info("invitation made", account_id: socket.assigns.current_account.id)
        # The token goes after `#`, which no request sends.
        link = url(~p"/invite") <> "#" <> invitation.token

        {:noreply,
         socket
         |> listed()
         |> assign(
           link: link,
           link_id: invitation.id,
           username: "",
           note: "",
           error: undelivered(invitation, link)
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, error: changeset_message(changeset))}
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

  # A username error comes only from email mode; named mode writes no username. The address
  # comes first, because the note is optional there.
  defp changeset_message(changeset) do
    case {changeset.errors[:username], changeset.errors[:note]} do
      {nil, nil} ->
        gettext("That invitation could not be written.")

      {nil, error} ->
        gettext("Note %{message}.", message: CoreComponents.translate_error(error))

      {error, _} ->
        gettext("Email address %{message}.", message: CoreComponents.translate_error(error))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      section={:invitations}
      title={gettext("Invitations")}
      back={%{to: ~p"/account/settings", label: gettext("Settings")}}
      breadcrumb
    >
      <.header>
        {gettext("Invitations")}
        <:subtitle>
          {gettext("Signed in as %{username}.", username: @current_account.username)}
        </:subtitle>
      </.header>

      <h2 class="mt-8 text-lg font-semibold">{gettext("Invite somebody")}</h2>

      <p :if={not @email?} class="mt-2 text-label opacity-70">
        {gettext("Note whom the link is for, then send it to them. They choose their own username.")}
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
          :if={@email?}
          type="email"
          name="username"
          value={@username}
          label={gettext("Their email address")}
          required
          placeholder="grace@example.org"
        />
        <.input
          name="note"
          value={@note}
          label={if @email?, do: gettext("Note (optional)"), else: gettext("Who is it for?")}
          placeholder={gettext("Grace, from the meetup")}
          maxlength="500"
          required={not @email?}
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
        <span>{gettext("Your invitation is ready. Send this link to your guest:")}</span>
        <div class="mt-2 flex items-start gap-2">
          <code id="invitation-link-text" class="min-w-0 flex-1 break-all py-1.5">{@link}</code>
          <button
            type="button"
            id={"copy-invitation-link-#{@link_id}"}
            phx-hook="CopyText"
            data-copy-text={@link}
            data-copy-status={"copy-link-status-#{@link_id}"}
            data-copy-success={gettext("Link copied.")}
            data-copy-error={gettext("Copying was blocked. Select the link and copy it yourself.")}
            aria-label={gettext("Copy link")}
            title={gettext("Copy link")}
            class="group inline-flex size-9 shrink-0 cursor-pointer items-center justify-center rounded-control border border-edge bg-surface text-muted hover:bg-ground hover:text-ink focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent"
          >
            <Lucideicons.copy aria-hidden="true" class="size-4 group-data-copied:hidden" />
            <Lucideicons.check
              aria-hidden="true"
              class="hidden size-4 text-signal-strong group-data-copied:block"
            />
          </button>
        </div>
      </div>

      <%!-- Outside the box, which is a live region of its own. One per link, so a new link
        starts without the last one's sentence. --%>
      <span
        :if={@link}
        id={"copy-link-status-#{@link_id}"}
        role="status"
        phx-update="ignore"
        class="mt-2 block min-h-5 text-label text-muted"
      ></span>

      <h2 class="mt-10 text-lg font-semibold">{gettext("Outstanding invitations")}</h2>

      <p :if={@pending == []} class="mt-2 text-label opacity-70">
        {gettext("Nothing is waiting to be accepted.")}
      </p>

      <p :if={@pending != []} class="mt-2 text-label opacity-70">
        {if @current_account.admin,
          do: gettext("As an administrator, you can take back any invitation until it is accepted."),
          else: gettext("You can take back the ones you sent, until they are accepted.")}
      </p>

      <ul :if={@pending != []} id="pending-invitations" class="mt-4 divide-y">
        <li
          :for={invitation <- @pending}
          id={"invitation-#{invitation.id}"}
          class="flex flex-wrap items-center gap-x-4 gap-y-1 py-3"
        >
          <span class="font-medium">{invitation.note || invitation.username}</span>
          <span :if={invitation.note && invitation.username} class="text-label opacity-70">
            {invitation.username}
          </span>

          <span class="text-label opacity-70">
            {gettext("Invited by %{username}", username: inviter(invitation))}
          </span>

          <span class="text-label opacity-70">
            {gettext("Made %{date}", date: on(invitation.inserted_at))}
          </span>

          <span class="text-label opacity-70">
            {gettext("Runs out %{date}", date: on(invitation.expires_at))}
          </span>

          <button
            :if={Invitations.withdrawable?(@current_account, invitation)}
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

  # The inviter column has no foreign key, so a removed inviter leaves its id behind. Rows from
  # before the column existed have none.
  defp inviter(%{invited_by: %{username: username}}), do: username
  defp inviter(%{invited_by_id: nil}), do: gettext("Unknown")
  defp inviter(_removed), do: gettext("a former member")

  # Uses the application's date format, `YYYY-MM-DD`.
  defp on(at), do: Calendar.strftime(at, "%Y-%m-%d")
end
