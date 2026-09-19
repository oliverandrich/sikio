defmodule SikioWeb.InvitationsLive do
  @moduledoc """
  Manual invitation links behind `{:require_account, to: "/login"}`.

  Nothing here checks who is asking: by the time `mount/3` runs, the gate has either assigned an
  account or sent the visitor away. What an account may *do* — whether everyone can invite, or only
  some — is this application's question and would live here, not in the library.
  """
  use SikioWeb, :live_view

  alias Sikio.Accounts.Invitation
  alias Sikio.Repo
  alias SikioWeb.CoreComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, username: "", link: nil, error: nil)}
  end

  @impl true
  def handle_event("validate", %{"username" => username}, socket) do
    {:noreply, assign(socket, username: username, error: nil)}
  end

  def handle_event("invite", %{"username" => username}, socket) do
    %Invitation{}
    |> Invitation.changeset(%{"username" => username})
    |> Repo.insert()
    |> case do
      # The token is the only copy there will ever be: the row holds its sha256, and the virtual
      # field is empty on anything read back later. So it goes on the screen now or not at all.
      {:ok, invitation} ->
        {:noreply, assign(socket, link: url(~p"/invite/#{invitation.token}"), username: "")}

      {:error, changeset} ->
        {:noreply, assign(socket, error: changeset_message(changeset))}
    end
  end

  defp changeset_message(changeset) do
    case changeset.errors do
      [{:username, error} | _rest] ->
        gettext("Username %{message}.", message: CoreComponents.translate_error(error))

      _other ->
        gettext("That invitation could not be written.")
    end
  end

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

      <p class="mt-2 text-sm opacity-70">
        {gettext("Choose a username for your guest, then send them their personal invitation link.")}
      </p>

      <form id="invitation-form" phx-change="validate" phx-submit="invite" class="mt-4">
        <.input
          name="username"
          value={@username}
          label={gettext("Their username")}
          required
          pattern={Layouts.username_pattern()}
          title={gettext("Letters, digits and underscores, up to thirty")}
          placeholder="grace_hopper"
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
