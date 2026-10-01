# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AccountSecurityLive do
  @moduledoc "Passkey enrollment and account recovery settings."
  use SikioWeb, :live_view

  alias Ithibati.Identity.Passkeys
  alias Ithibati.Identity.RecoveryCodes
  alias SikioWeb.CeremonyMessages
  alias SikioWeb.Reauth

  @impl true
  def mount(_params, session, socket) do
    account = socket.assigns.current_account

    {:ok,
     assign(socket,
       keys: Passkeys.list_keys(account),
       remaining: RecoveryCodes.remaining(account),
       error: nil,
       label: "",
       confirmed: Reauth.recent?(session, account)
     )}
  end

  @impl true
  def handle_event("validate", %{"label" => label}, socket) do
    {:noreply, assign(socket, label: label, error: nil)}
  end

  def handle_event("add-passkey", %{"label" => label}, socket) do
    {:noreply,
     socket
     |> assign(error: nil)
     |> push_event("ithibati:register", %{intent: "add_passkey", label: label})}
  end

  def handle_event("ithibati:failed", %{"error" => "reauthentication_required"}, socket) do
    {:noreply, redirect(socket, to: ~p"/account/confirm/passkeys")}
  end

  def handle_event("ithibati:failed", %{"error" => error} = payload, socket) do
    {:noreply, assign(socket, error: CeremonyMessages.message(error, payload["exception"]))}
  end

  def handle_event("ithibati:done", _payload, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member flash={@flash} current_account={@current_account} sidebar={@sidebar}>
      <section :if={@live_action == :passkeys}>
        <.header>
          {gettext("Manage passkeys")}
          <:subtitle>
            {gettext("Give your passkeys recognizable names and keep a spare for another device.")}
          </:subtitle>
        </.header>
        <p :if={@error} role="alert" class="my-4 text-label text-danger">{@error}</p>
        <div class="mt-6 space-y-4">
          <article
            :for={key <- @keys}
            id={"key-#{key.id}"}
            class="rounded-control border border-line bg-surface p-5"
          >
            <.form for={%{}} action={~p"/account/passkeys/#{key.id}"} method="patch" class="space-y-3">
              <.input
                name="label"
                value={key.label}
                label={gettext("Passkey name")}
                maxlength="100"
                required
              />
              <p class="text-meta text-muted">
                {gettext("Added %{date}", date: Calendar.strftime(key.inserted_at, "%Y-%m-%d"))}
              </p>
              <.button>{gettext("Save name")}</.button>
            </.form>
            <.form for={%{}} action={~p"/account/passkeys/#{key.id}"} method="delete" class="mt-3">
              <.button
                disabled={length(@keys) == 1}
                data-confirm={
                  gettext("Remove this passkey? You will no longer be able to sign in with it.")
                }
              >{gettext("Remove passkey")}</.button>
            </.form>
          </article>
        </div>
        <p :if={length(@keys) == 1} class="mt-3 text-label text-muted">
          {gettext("Add another passkey before removing your last one.")}
        </p>
        <div class="mt-8 rounded-control border border-accent bg-selection p-6">
          <h2 class="mb-4 text-lg font-semibold">{gettext("Add a passkey")}</h2>
          <.link
            :if={!@confirmed}
            href={~p"/account/confirm/passkeys"}
            class="font-medium text-accent"
          >{gettext("Confirm your identity to add a passkey")}</.link>
          <form :if={@confirmed} id="add-passkey-form" phx-change="validate" phx-submit="add-passkey">
            <.input
              name="label"
              value={@label}
              label={gettext("Passkey name")}
              placeholder={gettext("For example: laptop or phone")}
              maxlength="100"
              required
            />
            <Layouts.auth_button type="submit">{gettext("Add a passkey")}</Layouts.auth_button>
          </form>
        </div>
        <section class="mt-8 border-t border-line pt-6">
          <h2 class="text-lg font-semibold">{gettext("Sessions")}</h2>
          <p class="my-3 text-label text-muted">
            {gettext("Sign out on every device, including this one. Your passkeys will still work.")}
          </p>
          <.form for={%{}} action={~p"/account/sessions"} method="delete">
            <.button data-confirm={gettext("Sign out on all devices?")}>{gettext(
              "Sign out on all devices"
            )}</.button>
          </.form>
        </section>
        <Layouts.passkey_ceremony />
      </section>
      <section :if={@live_action == :recovery_codes}>
        <.header>
          {gettext("Recovery codes")}
          <:subtitle>
            {gettext("Keep your recovery codes somewhere safe, separate from your devices.")}
          </:subtitle>
        </.header>
        <div class="mt-6 rounded-control border border-line bg-surface p-6">
          <p class="text-lg font-semibold">
            {ngettext(
              "You have %{count} unused recovery code.",
              "You have %{count} unused recovery codes.",
              @remaining
            )}
          </p>
          <p class="mt-3 text-label leading-6 text-muted">
            {gettext(
              "For your security, existing codes cannot be shown again. Generate a new set if you have lost them."
            )}
          </p>
          <.link
            :if={!@confirmed}
            href={~p"/account/confirm/recovery-codes"}
            class="mt-6 block font-medium text-accent"
          >{gettext("Confirm your identity to generate new codes")}</.link>
          <.form
            :if={@confirmed}
            for={%{}}
            id="regenerate-codes-form"
            action={~p"/account/recovery-codes"}
            class="mt-6"
          >
            <label class="mb-6 flex items-start gap-3 text-label leading-6">
              <input
                type="checkbox"
                name="confirm"
                value="true"
                required
                class="mt-1 size-4 accent-accent"
              />
              <span>{gettext("I understand that all my previous recovery codes will stop working.")}</span>
            </label>
            <Layouts.auth_button type="submit">{gettext("Generate new recovery codes")}</Layouts.auth_button>
          </.form>
        </div>
      </section>
    </Layouts.member>
    """
  end
end
