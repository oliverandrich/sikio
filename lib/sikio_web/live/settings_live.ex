# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SettingsLive do
  @moduledoc """
  A member's preferences: Play on and the interface language. Each change saves at once.

  A changed language redirects to this page, so the whole document renders in it.
  """
  use SikioWeb, :live_view

  alias Sikio.Preferences

  # Each language is named in itself, so it is recognizable from any other.
  @languages [{"English", "en"}, {"Deutsch", "de"}]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket, preference: Preferences.get(socket.assigns.current_account), saved?: false)}
  end

  @impl true
  # The stored language is read again, since another tab may have changed it.
  # A failed save shows the stored values again.
  def handle_event("save", params, socket) do
    account = socket.assigns.current_account
    before = Preferences.get(account).locale

    case Preferences.update(account, Map.take(params, ["play_on", "locale"])) do
      {:ok, %{locale: ^before} = preference} ->
        {:noreply, socket |> clear_flash() |> assign(preference: preference, saved?: true)}

      {:ok, _preference} ->
        {:noreply, redirect(socket, to: ~p"/account/settings")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(preference: Preferences.get(account), saved?: false)
         |> put_flash(:error, gettext("The settings could not be saved."))}
    end
  end

  defp languages,
    do: Enum.filter(@languages, fn {_name, code} -> code in Preferences.locales() end)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.member
      flash={@flash}
      current_account={@current_account}
      sidebar={@sidebar}
      section={:settings}
      title={gettext("Settings")}
      back={%{to: ~p"/library", label: gettext("Library")}}
    >
      <.header>{gettext("Settings")}</.header>
      <form id="settings-form" phx-change="save" class="mt-6 max-w-xl">
        <.input
          id="settings-play-on"
          type="checkbox"
          name="play_on"
          checked={@preference.play_on}
          label={gettext("Play on with the queue when an item ends")}
        />
        <.input
          id="settings-locale"
          type="select"
          name="locale"
          label={gettext("Language")}
          prompt={gettext("The browser's language")}
          value={@preference.locale}
          options={for {name, code} <- languages(), do: [key: name, value: code, lang: code]}
        />
        <%!-- The status region exists from the start, so screen readers announce its text. --%>
        <p id="settings-saved" role="status" class="text-label text-muted">
          {if @saved?, do: gettext("Saved.")}
        </p>
      </form>
    </Layouts.member>
    """
  end
end
