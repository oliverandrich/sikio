# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MarkAll do
  @moduledoc """
  LiveComponent with the dialog that archives every item of a list.

  The parent counts first and opens it with `send_update/2` and `open: {count, filters}`.
  `open: :close` closes it. The checkboxes recount what would be archived. The archive triggers a
  PubSub broadcast, which reloads the parent's list and sidebar.
  """
  use SikioWeb, :live_component

  alias Sikio.Playback

  @impl true
  def mount(socket), do: {:ok, assign(socket, count: nil, filters: nil, options: nil)}

  @impl true
  def update(%{open: {count, filters}}, socket) do
    options = %{in_progress: true, playing: true, playing_id: nil}
    {:ok, assign(socket, count: count, filters: filters, options: options)}
  end

  def update(%{open: :close}, socket), do: {:ok, assign(socket, :count, nil)}

  def update(assigns, socket),
    do: {:ok, assign(socket, Map.take(assigns, [:id, :current_account]))}

  # A checkbox change recounts the items to archive. The parent does not hold the playing item,
  # so the client sends its id; see assets/js/playing_entry.mjs.
  @impl true
  def handle_event("mark_options", params, socket) do
    options = %{
      in_progress: params["in_progress"] != "false",
      playing: params["playing"] != "false",
      playing_id: entry_id(params["playing_id"])
    }

    %{current_account: account, filters: filters} = socket.assigns
    count = Playback.markable(account, filters, marking(options))
    {:noreply, assign(socket, count: count, options: options)}
  end

  def handle_event("cancel_mark_all", _params, socket),
    do: {:noreply, socket |> assign(:count, nil) |> push_event("focus", %{id: "mark-all"})}

  # Ignores a repeated click that arrives after the first closed the dialog.
  def handle_event("confirm_mark_all", _params, %{assigns: %{count: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_mark_all", _params, socket) do
    %{current_account: account, filters: filters, options: options} = socket.assigns
    {:ok, _count} = Playback.mark_all(account, filters, marking(options))
    {:noreply, assign(socket, :count, nil)}
  end

  # Converts the dialog's checkboxes into the exclusion options of `Playback.mark_all/3`.
  defp marking(%{in_progress: in_progress, playing: playing, playing_id: playing_id}),
    do: [in_progress: in_progress, keep: if(playing, do: nil, else: playing_id)]

  defp entry_id(value) do
    case Integer.parse(value || "") do
      {id, ""} -> id
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.confirm_dialog
        :if={@count}
        name="mark-all"
        title={gettext("Archive everything here?")}
        confirm_label={gettext("Archive")}
        target={@myself}
      >
        <p>
          {ngettext(
            "%{count} item in this list will be archived. It stays out of your history.",
            "%{count} items in this list will be archived. They stay out of your history.",
            @count
          )}
        </p>
        <form
          id="mark-all-options"
          phx-change="mark_options"
          phx-target={@myself}
          class="mt-4 flex flex-col gap-2"
        >
          <label class="flex items-center gap-2.5 text-label text-ink">
            <input type="hidden" name="in_progress" value="false" />
            <input
              type="checkbox"
              name="in_progress"
              value="true"
              checked={@options.in_progress}
              class="size-4 accent-accent"
            />
            {gettext("Include items in progress")}
          </label>
          <%!-- The PlayingEntry hook shows this only while the player has an item. --%>
          <div
            id="mark-all-playing"
            phx-hook="PlayingEntry"
            phx-mounted={JS.ignore_attributes(["hidden"])}
            hidden
          >
            <input type="hidden" name="playing_id" value={@options.playing_id} />
            <label class="flex items-center gap-2.5 text-label text-ink">
              <input type="hidden" name="playing" value="false" />
              <input
                type="checkbox"
                name="playing"
                value="true"
                checked={@options.playing}
                class="size-4 accent-accent"
              />
              {gettext("Include the item in the player")}
            </label>
          </div>
        </form>
      </.confirm_dialog>
    </div>
    """
  end
end
