# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AccountsLive do
  @moduledoc """
  Lists every account for an administrator, with its creation date and role. An administrator
  grants or revokes the role on another account's row, or removes that account.

  `SikioWeb.Admin` turns members away before `mount/3` runs. Every `Sikio.Accounts` call checks
  the role again in its query, for a role revoked in between.

  Granting the role and removing an account ask for a confirmation from the last five minutes,
  as the security settings do. A new administrator could remove any account, so granting counts
  as much as removing. Removing also asks for the dialog's answer, and the five minutes are read
  again then. The removed account's open pages are disconnected after the commit.
  """
  use SikioWeb, :live_view

  alias Ithibati.Web.Gate
  alias Sikio.Accounts
  alias SikioWeb.Admin
  alias SikioWeb.Reauth

  on_mount {SikioWeb.Admin, :require_admin}

  @impl true
  def mount(_params, session, socket) do
    socket =
      assign(socket,
        page_title: gettext("Accounts"),
        removing: nil,
        # `Reauth.recent?/2` reads these again on each removal, so the five minutes still count.
        confirmation: Map.take(session, ["confirmed_account_id", "confirmed_at"])
      )

    {:ok, listed(socket)}
  end

  @impl true
  def handle_event("grant", %{"id" => id}, socket) do
    if confirmed?(socket),
      do: {:noreply, changed(socket, Accounts.grant_admin(socket.assigns.current_account, id))},
      else: {:noreply, to_confirmation(socket)}
  end

  def handle_event("revoke", %{"id" => id}, socket),
    do: {:noreply, changed(socket, Accounts.revoke_admin(socket.assigns.current_account, id))}

  def handle_event("remove", %{"id" => id}, socket) do
    own = socket.assigns.current_account.id

    cond do
      not confirmed?(socket) ->
        {:noreply, to_confirmation(socket)}

      account = Enum.find(socket.assigns.accounts, &(to_string(&1.id) == id and &1.id != own)) ->
        {:noreply, assign(socket, removing: account)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_remove", _params, socket),
    do: {:noreply, assign(socket, removing: nil)}

  def handle_event("confirm_remove", _params, %{assigns: %{removing: %{} = account}} = socket) do
    socket = assign(socket, removing: nil)

    with true <- confirmed?(socket) || :expired,
         {:ok, digests} <- Accounts.remove_account(socket.assigns.current_account, account.id) do
      Gate.disconnect_sessions(socket.endpoint, digests)

      {:noreply,
       socket
       |> put_flash(:info, gettext("Removed %{username}.", username: account.username))
       |> listed()}
    else
      :expired -> {:noreply, to_confirmation(socket)}
      error -> {:noreply, changed(socket, error)}
    end
  end

  def handle_event("confirm_remove", _params, socket), do: {:noreply, socket}

  defp confirmed?(socket),
    do: Reauth.recent?(socket.assigns.confirmation, socket.assigns.current_account)

  defp to_confirmation(socket), do: redirect(socket, to: ~p"/account/confirm/accounts")

  defp changed(socket, {:ok, _result}), do: listed(socket)

  defp changed(socket, {:error, :forbidden}), do: Admin.turn_away(socket)

  defp changed(socket, {:error, :last_admin}),
    do: put_flash(socket, :error, gettext("The last administrator keeps the role."))

  defp changed(socket, {:error, :self}),
    do: put_flash(socket, :error, gettext("Your own account cannot be removed here."))

  defp changed(socket, {:error, :not_found}),
    do:
      socket
      |> put_flash(:error, gettext("This account no longer exists."))
      |> listed()

  defp changed(socket, {:error, _changeset}),
    do: put_flash(socket, :error, gettext("Nothing changed. Please try again."))

  defp listed(socket) do
    case Accounts.list_accounts(socket.assigns.current_account) do
      {:ok, accounts} -> assign(socket, accounts: accounts)
      {:error, :forbidden} -> Admin.turn_away(socket)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      section={:accounts}
      title={gettext("Accounts")}
      back={%{to: ~p"/account/settings", label: gettext("Settings")}}
      breadcrumb
    >
      <.header>
        {gettext("Accounts")}
        <:subtitle>
          {ngettext(
            "1 account on this instance.",
            "%{count} accounts on this instance.",
            length(@accounts)
          )}
        </:subtitle>
      </.header>

      <ul id="accounts" class="mt-6 divide-y divide-line">
        <li
          :for={account <- @accounts}
          id={"account-#{account.id}"}
          class="flex flex-col gap-2 py-3 sm:flex-row sm:items-center sm:gap-4"
        >
          <div class="min-w-0 flex-1">
            <p class="flex flex-wrap items-baseline gap-x-3">
              <span class="font-medium">{account.username}</span>
              <span :if={account.name} class="text-label text-muted">{account.name}</span>
            </p>
            <p class="meta-dots flex flex-wrap items-center text-label text-muted">
              <span>
                {gettext("Joined %{date}",
                  date: Calendar.strftime(account.inserted_at, "%Y-%m-%d")
                )}
              </span>
              <span class={account.admin && "font-semibold text-ink"}>
                {if account.admin, do: gettext("Administrator"), else: gettext("Member")}
              </span>
            </p>
          </div>
          <%!-- No actions on the own row: removing oneself is a different question. --%>
          <div
            :if={account.id != @current_account.id}
            class="flex flex-wrap gap-x-4 gap-y-1 text-label"
          >
            <button
              :if={not account.admin}
              type="button"
              data-action="grant"
              phx-click="grant"
              phx-value-id={account.id}
              class="underline underline-offset-4"
            >
              {gettext("Make administrator")}
            </button>
            <button
              :if={account.admin}
              type="button"
              data-action="revoke"
              phx-click="revoke"
              phx-value-id={account.id}
              class="underline underline-offset-4"
            >
              {gettext("Revoke administrator")}
            </button>
            <button
              type="button"
              data-action="remove"
              phx-click="remove"
              phx-value-id={account.id}
              class="text-danger underline underline-offset-4"
            >
              {gettext("Remove")}
            </button>
          </div>
        </li>
      </ul>

      <.confirm_dialog
        :if={@removing}
        name="remove"
        title={gettext("Remove %{username}?", username: @removing.username)}
        confirm_label={gettext("Remove")}
        variant="danger"
      >
        {gettext(
          "Their subscriptions, playback, tags and passkeys are deleted, and their open sessions end. This cannot be undone."
        )}
      </.confirm_dialog>
    </Layouts.member>
    """
  end
end
