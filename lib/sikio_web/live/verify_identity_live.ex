defmodule SikioWeb.VerifyIdentityLive do
  @moduledoc "Confirm the current account without switching users or creating a new session."
  use SikioWeb, :live_view
  alias SikioWeb.CeremonyMessages

  @impl true
  def mount(_params, session, socket) do
    if session["reauth_target"] in ["/account/passkeys", "/account/recovery-codes"] do
      {:ok, assign(socket, error: nil, code: "")}
    else
      {:ok, redirect(socket, to: ~p"/account/passkeys")}
    end
  end

  @impl true
  def handle_event("validate", %{"code" => code}, socket),
    do: {:noreply, assign(socket, code: code, error: nil)}

  def handle_event("confirm", _params, socket),
    do: {:noreply, push_event(socket, "ithibati:authenticate", %{})}

  def handle_event("recover", %{"code" => code}, socket),
    do: {:noreply, push_event(socket, "ithibati:recover", %{code: code})}

  def handle_event("ithibati:failed", %{"error" => error} = payload, socket),
    do: {:noreply, assign(socket, error: CeremonyMessages.message(error, payload["exception"]))}

  def handle_event("ithibati:done", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      title={gettext("Confirm your identity")}
      subtitle={
        gettext(
          "Confirm your current account before changing its security settings. Confirmation lasts five minutes."
        )
      }
    >
      <p :if={@error} role="alert" class="mb-4 text-sm text-red-700 dark:text-red-400">{@error}</p>
      <Layouts.auth_button phx-click="confirm">{gettext("Confirm with a passkey")}</Layouts.auth_button>
      <details
        id="recovery-confirmation"
        phx-mounted={JS.ignore_attributes(["open"])}
        class="mt-6 text-sm"
      >
        <summary class="cursor-pointer text-violet-600 dark:text-violet-400">
          {gettext("Use a recovery code instead")}
        </summary>
        <.form for={%{}} id="confirm-recovery" phx-change="validate" phx-submit="recover" class="mt-4">
          <.input
            name="code"
            value={@code}
            label={gettext("Recovery code")}
            required
            autocomplete="off"
          />
          <Layouts.auth_button type="submit">{gettext("Confirm with a recovery code")}</Layouts.auth_button>
        </.form>
      </details>
      <.link
        navigate={~p"/account/passkeys"}
        class="mt-6 block text-center text-sm text-violet-600 dark:text-violet-400"
      >{gettext("Cancel")}</.link>
      <Layouts.passkey_ceremony />
    </Layouts.auth>
    """
  end
end
