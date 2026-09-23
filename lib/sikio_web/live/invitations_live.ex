# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.InvitationsLive do
  @moduledoc """
  Manual invitation links behind `{:require_account, to: "/login"}`.

  Nothing here checks who is asking: by the time `mount/3` runs, the gate has either assigned an
  account or sent the visitor away. What an account may *do* — whether everyone can invite, or only
  some — is this application's question and would live here, not in the library.
  """
  use SikioWeb, :live_view

  alias Sikio.Accounts.Invitation
  alias Sikio.AuthRateLimiter
  alias Sikio.Identity
  alias Sikio.Repo
  alias SikioWeb.AuthRateLimit
  alias SikioWeb.CoreComponents
  alias SikioWeb.InvitationMail

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, username: "", link: nil, error: nil, email?: Identity.email?())}
  end

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

  defp create(socket, username) do
    %Invitation{}
    |> Invitation.changeset(%{"username" => username})
    |> Repo.insert()
    |> case do
      # The token is the only copy there will ever be: the row holds its sha256, and the virtual
      # field is empty on anything read back later. So it goes on the screen now or not at all.
      {:ok, invitation} ->
        link = url(~p"/invite/#{invitation.token}")

        {:noreply, assign(socket, link: link, username: "", error: undelivered(invitation, link))}

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
    <Layouts.member flash={@flash} current_account={@current_account}>
      <.header>
        {gettext("Welcome home")}
        <:subtitle>
          {gettext("Signed in as %{username}.", username: @current_account.username)}
        </:subtitle>
      </.header>

      <h2 class="mt-8 text-lg font-semibold">{gettext("Invite somebody")}</h2>

      <p :if={not @email?} class="mt-2 text-sm opacity-70">
        {gettext("Choose a username for your guest, then send them their personal invitation link.")}
      </p>

      <p :if={@email?} class="mt-2 text-sm opacity-70">
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
        class="rounded-lg border p-4 border-red-300 bg-red-50 text-red-950 dark:border-red-700 dark:bg-red-950 dark:text-red-100 mt-4"
      >
        <span>{@error}</span>
      </div>

      <div
        :if={@link}
        role="status"
        class="rounded-lg border p-4 border-emerald-300 bg-emerald-50 text-emerald-950 dark:border-emerald-700 dark:bg-emerald-950 dark:text-emerald-100 mt-4"
      >
        <span>
          {gettext("Your invitation is ready. Send this link to your guest:")}
          <code class="block mt-2 break-all">{@link}</code>
        </span>
      </div>
    </Layouts.member>
    """
  end
end
