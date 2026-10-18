# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.AccountsLive do
  @moduledoc """
  Lists every account for an administrator, with its creation date and role.

  `SikioWeb.Admin` turns members away before `mount/3` runs. `Sikio.Accounts.list_accounts/1`
  checks the role again in its query, for a role revoked in between.
  """
  use SikioWeb, :live_view

  alias Sikio.Accounts

  on_mount {SikioWeb.Admin, :require_admin}

  @impl true
  def mount(_params, _session, socket) do
    case Accounts.list_accounts(socket.assigns.current_account) do
      {:ok, accounts} ->
        {:ok, assign(socket, page_title: gettext("Accounts"), accounts: accounts)}

      {:error, :forbidden} ->
        {:ok, SikioWeb.Admin.turn_away(socket)}
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
          class="flex flex-wrap items-center gap-x-4 gap-y-1 py-3"
        >
          <span class="font-medium">{account.username}</span>
          <span :if={account.name} class="text-label text-muted">{account.name}</span>
          <span class="text-label text-muted">
            {gettext("Joined %{date}", date: Calendar.strftime(account.inserted_at, "%Y-%m-%d"))}
          </span>
          <span class={[
            "ml-auto text-label",
            if(account.admin, do: "font-semibold text-ink", else: "text-muted")
          ]}>
            {if account.admin, do: gettext("Administrator"), else: gettext("Member")}
          </span>
        </li>
      </ul>
    </Layouts.member>
    """
  end
end
