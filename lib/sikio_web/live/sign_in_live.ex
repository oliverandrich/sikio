# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SignInLive do
  @moduledoc """
  The LiveView says *when* a ceremony starts; the hook does the round-trips.

  That split is not a style choice. A ceremony ends in a session cookie and a LiveView cannot set
  one, so the hook posts to the endpoints over `fetch` and follows the redirect the handler answers
  with. What a LiveView is good at — validating the fields before any of that begins — is what it
  does here.
  """
  use SikioWeb, :live_view

  alias Ithibati.Identity.Instance
  alias Sikio.Identity
  alias SikioWeb.Auth
  alias SikioWeb.CeremonyMessages

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     assign(socket,
       username: "",
       error: nil,
       claim_open?: claim_open?(socket, session),
       email?: Identity.email?()
     )}
  end

  # Whether this visitor may be asked for a name yet. A proof that has run out sends somebody back
  # to the code rather than to a refusal after the passkey dialogue.
  #
  # Only the setup page asks. Anywhere else the question is a database round-trip for an answer
  # nothing on the page reads.
  defp claim_open?(%{assigns: %{live_action: :setup}}, session),
    do: Auth.claim_open?(session["setup_authorization"])

  defp claim_open?(_socket, _session), do: true

  @impl true
  def handle_params(_params, _uri, socket) do
    needs_setup? = Instance.needs_setup?()

    cond do
      socket.assigns.current_account ->
        {:noreply, redirect(socket, to: ~p"/")}

      needs_setup? and socket.assigns.live_action != :setup ->
        {:noreply, redirect(socket, to: ~p"/setup")}

      not needs_setup? and socket.assigns.live_action == :setup ->
        {:noreply, redirect(socket, to: ~p"/login")}

      true ->
        {:noreply, assign(socket, error: nil)}
    end
  end

  @impl true
  def handle_event("validate", %{"username" => username}, socket) do
    {:noreply, assign(socket, username: username, error: nil)}
  end

  def handle_event("register", %{"username" => username}, socket) do
    # Pushed to the hook, which takes it from here.
    {:noreply,
     socket |> assign(error: nil) |> push_event("ithibati:register", %{username: username})}
  end

  def handle_event("sign-in", _params, socket) do
    {:noreply, socket |> assign(error: nil) |> push_event("ithibati:authenticate", %{})}
  end

  def handle_event("recover", %{"code" => code}, socket) do
    {:noreply, socket |> assign(error: nil) |> push_event("ithibati:recover", %{code: code})}
  end

  # What the hook pushes back. A successful ceremony ends in the redirect the handler answered with,
  # so the only thing that reaches the LiveView is a failure.
  def handle_event("ithibati:failed", %{"error" => error} = payload, socket) do
    {:noreply, assign(socket, error: CeremonyMessages.message(error, payload["exception"]))}
  end

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      title={title(@live_action)}
      subtitle={subtitle(@live_action, @claim_open?, @email?)}
    >
      <div
        :if={@error}
        role="alert"
        class="mb-6 rounded-control border border-danger bg-danger-surface p-4 text-label text-danger"
      >
        {@error}
      </div>

      <div :if={@live_action == :login}>
        <h1 class="sr-only">{gettext("Sign in")}</h1>
        <Layouts.auth_button phx-click="sign-in">{gettext("Sign in with a passkey")}</Layouts.auth_button>
        <p class="mt-6 text-center text-label">
          <.link
            navigate={~p"/recover"}
            class="text-accent underline-offset-4 hover:underline"
          >{gettext("Lost your passkey? Use a recovery code")}</.link>
        </p>
      </div>

      <.form
        :if={@live_action == :setup and not @claim_open?}
        for={%{}}
        id="setup-code-form"
        action={~p"/setup/code"}
      >
        <.input
          name="setup_code"
          value=""
          label={gettext("Setup code")}
          autocomplete="off"
          required
          placeholder={gettext("The code from the operator")}
        />
        <Layouts.auth_button>{gettext("Continue")}</Layouts.auth_button>
      </.form>

      <form
        :if={@live_action == :setup and @claim_open?}
        id="claim-form"
        phx-change="validate"
        phx-submit="register"
      >
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
        <Layouts.auth_button>{gettext("Create your passkey")}</Layouts.auth_button>
      </form>

      <div :if={@live_action == :recover}>
        <form id="recovery-form" phx-submit="recover" phx-auto-recover="ignore">
          <.input
            name="code"
            value=""
            label={gettext("Recovery code")}
            autocomplete="off"
            spellcheck="false"
            required
          />
          <Layouts.auth_button>{gettext("Sign in with a recovery code")}</Layouts.auth_button>
        </form>
        <p class="mt-6 text-center text-label">
          <.link
            navigate={~p"/login"}
            class="text-accent underline-offset-4 hover:underline"
          >{gettext("Back to passkey sign-in")}</.link>
        </p>
      </div>

      <Layouts.passkey_ceremony />
    </Layouts.auth>
    """
  end

  defp title(:login), do: nil
  defp title(:setup), do: gettext("Make yourself at home")
  defp title(:recover), do: gettext("Use a recovery code")

  defp subtitle(:login, _claim_open?, _email?), do: nil

  defp subtitle(:setup, true, true),
    do: gettext("Enter your email address and create a passkey to set up your account.")

  defp subtitle(:setup, true, false),
    do: gettext("Choose your username and create a passkey to set up your account.")

  defp subtitle(:setup, false, _email?),
    do: gettext("This instance asks for a setup code before the first account is made.")

  defp subtitle(:recover, _claim_open?, _email?),
    do:
      gettext(
        "Enter one of the codes you saved when you set up your account. Each code works once."
      )
end
