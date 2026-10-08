# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SettingsLive do
  @moduledoc """
  A member's preferences in grouped cards: the start page, the language and Play on, which
  save at each change, and rows that lead to the account pages.

  A changed language redirects to this page, so the whole document renders in it.
  """
  use SikioWeb, :live_view

  alias Ithibati.Identity.Passkeys
  alias Ithibati.Identity.RecoveryCodes
  alias Sikio.Preferences

  # Each language is named in itself, so it is recognizable from any other.
  @languages [{"English", "en"}, {"Deutsch", "de"}]

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_account

    {:ok,
     assign(socket,
       preference: Preferences.get(account),
       saved?: false,
       passkeys: length(Passkeys.list_keys(account)),
       codes: RecoveryCodes.remaining(account)
     )}
  end

  @impl true
  # The stored language is read again, since another tab may have changed it.
  # A failed save shows the stored values again.
  def handle_event("save", params, socket) do
    account = socket.assigns.current_account
    before = Preferences.get(account).locale

    case Preferences.update(account, attrs(params)) do
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

  # Only the field that changed is saved, so a stale value elsewhere in the form is not.
  defp attrs(%{"_target" => [field | _]} = params), do: params |> Map.take([field]) |> fields()
  defp attrs(params), do: fields(params)

  defp fields(params),
    do: params |> Map.take(["play_on", "locale"]) |> Map.merge(start(params["start"]))

  # A tag replaces the list as the start page. Choosing a list clears the tag.
  defp start("tag-" <> id), do: %{"start_tag_id" => id}
  defp start(view) when is_binary(view), do: %{"start_view" => view, "start_tag_id" => nil}
  defp start(nil), do: %{}

  defp chosen_start(%{start_tag_id: nil, start_view: view}), do: view
  defp chosen_start(%{start_tag_id: id}), do: "tag-#{id}"

  defp start_options(tags),
    do:
      [{gettext("Queue"), "queue"}, {gettext("Inbox"), "inbox"}] ++
        Enum.map(tags, &{&1.name, "tag-#{&1.id}"})

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
      <h1 data-large-title class="mb-6 text-title font-semibold">{gettext("Settings")}</h1>
      <div class="max-w-xl">
        <form id="settings-form" phx-change="save">
          <.group id="settings-general" heading={gettext("General")}>
            <.setting for="settings-start" label={gettext("Start page")}>
              <select id="settings-start" name="start" class={select_class()}>
                {Phoenix.HTML.Form.options_for_select(
                  start_options(@sidebar.tags),
                  chosen_start(@preference)
                )}
              </select>
            </.setting>
            <.setting for="settings-locale" label={gettext("Language")}>
              <select id="settings-locale" name="locale" class={select_class()}>
                <option value="">{gettext("The browser's language")}</option>
                {Phoenix.HTML.Form.options_for_select(
                  for({name, code} <- languages(), do: [key: name, value: code, lang: code]),
                  @preference.locale
                )}
              </select>
            </.setting>
          </.group>
          <.group id="settings-playback" heading={gettext("Playback")}>
            <.setting
              for="settings-play-on"
              label={gettext("Play on with the queue")}
              hint={gettext("When an item ends, the next one in the queue starts.")}
              hint_id="settings-play-on-hint"
            >
              <span class="relative inline-flex shrink-0">
                <input type="hidden" name="play_on" value="false" />
                <input
                  id="settings-play-on"
                  type="checkbox"
                  role="switch"
                  name="play_on"
                  value="true"
                  checked={@preference.play_on}
                  aria-describedby="settings-play-on-hint"
                  class="peer absolute inset-0 size-full cursor-pointer appearance-none rounded-full"
                />
                <span
                  aria-hidden="true"
                  class="pointer-events-none h-6 w-10 rounded-full bg-track transition-colors peer-checked:bg-accent peer-focus-visible:outline-2 peer-focus-visible:outline-offset-2 peer-focus-visible:outline-accent forced-colors:border forced-colors:border-[CanvasText] forced-colors:peer-checked:bg-[Highlight]"
                ></span>
                <span
                  aria-hidden="true"
                  class="pointer-events-none absolute top-0.5 left-0.5 size-5 rounded-full bg-surface shadow-xs transition-transform peer-checked:translate-x-4 forced-colors:bg-[CanvasText]"
                ></span>
              </span>
            </.setting>
          </.group>
        </form>
        <.group id="settings-account" heading={gettext("Account & security")} tag="nav">
          <.group_link to={~p"/account/passkeys"} detail={@passkeys}>
            {gettext("Passkeys")}
          </.group_link>
          <.group_link
            to={~p"/account/recovery-codes"}
            detail={ngettext("1 left", "%{count} left", @codes)}
          >
            {gettext("Recovery codes")}
          </.group_link>
          <.group_link to={~p"/invitations"}>{gettext("Invitations")}</.group_link>
        </.group>
        <%!-- The status region exists from the start, so screen readers announce its text. --%>
        <p id="settings-saved" role="status" class="px-4 text-label text-muted">
          {if @saved?, do: gettext("Saved.")}
        </p>
      </div>
    </Layouts.member>
    """
  end

  attr :for, :string, required: true, doc: "the id of the control"
  attr :label, :string, required: true
  attr :hint, :string, default: nil

  attr :hint_id, :string,
    default: nil,
    doc: "the hint's id, which the control describes itself by"

  slot :inner_block, required: true

  # A row of a settings group: its label and hint on the left, its control on the right.
  # The hint stays outside the label, so it is not part of the control's name.
  defp setting(assigns) do
    ~H"""
    <div class="flex min-h-12 items-center justify-between gap-4 px-4 py-2.5">
      <div class="min-w-0">
        <label for={@for} class="block text-body text-ink">{@label}</label>
        <p :if={@hint} id={@hint_id} class="text-label text-muted">{@hint}</p>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp select_class,
    do:
      "max-w-60 shrink-0 rounded-control border border-control bg-surface py-1.5 pr-8 pl-2.5 text-label text-ink focus:border-accent focus:outline-2 focus:outline-accent"
end
