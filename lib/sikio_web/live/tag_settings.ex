# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.TagSettings do
  @moduledoc """
  LiveComponent with the rename and delete dialogs for one tag.

  The parent opens it with `send_update/2` and `open: {:rename, tag}` or `open: {:delete, tag}`.
  `open: :close` closes it. The parent process then receives `{#{inspect(__MODULE__)}, :renamed}`
  or `:deleted`. A taken or blank name keeps the rename dialog open with the error.
  """
  use SikioWeb, :live_component

  alias Sikio.Tags

  @impl true
  def mount(socket), do: {:ok, assign(socket, renaming: nil, deleting: nil)}

  @impl true
  def update(%{open: {:rename, tag}}, socket),
    do: {:ok, assign(socket, renaming: %{tag: tag, name: tag.name, error: nil}, deleting: nil)}

  def update(%{open: {:delete, tag}}, socket),
    do: {:ok, assign(socket, deleting: tag, renaming: nil)}

  def update(%{open: :close}, socket), do: {:ok, assign(socket, renaming: nil, deleting: nil)}

  def update(assigns, socket),
    do: {:ok, assign(socket, Map.take(assigns, [:id, :current_account]))}

  @impl true
  def handle_event("rename_options", %{"name" => name}, socket),
    do: {:noreply, take_name(socket, name)}

  # Enter in the field submits the form. It renames like the Rename button.
  def handle_event("submit_rename_tag", %{"name" => name}, socket),
    do: {:noreply, socket |> take_name(name) |> rename()}

  def handle_event("confirm_rename_tag", _params, socket), do: {:noreply, rename(socket)}

  def handle_event("cancel_rename_tag", _params, socket),
    do: {:noreply, socket |> assign(:renaming, nil) |> push_event("focus", %{id: "rename-tag"})}

  # Ignores a repeated click that arrives after the first closed the dialog.
  def handle_event("confirm_delete_tag", _params, %{assigns: %{deleting: nil}} = socket),
    do: {:noreply, socket}

  # The subscriptions stay; only the tag goes.
  def handle_event("confirm_delete_tag", _params, socket) do
    Tags.delete(socket.assigns.current_account, socket.assigns.deleting.id)
    send(self(), {__MODULE__, :deleted})
    {:noreply, assign(socket, :deleting, nil)}
  end

  def handle_event("cancel_delete_tag", _params, socket),
    do: {:noreply, socket |> assign(:deleting, nil) |> push_event("focus", %{id: "delete-tag"})}

  defp take_name(socket, name), do: update(socket, :renaming, &%{&1 | name: name, error: nil})

  # Ignores a repeated click that arrives after the first closed the dialog.
  defp rename(%{assigns: %{renaming: nil}} = socket), do: socket

  defp rename(socket) do
    %{tag: tag, name: name} = socket.assigns.renaming

    case Tags.rename(socket.assigns.current_account, tag.id, name) do
      {:ok, _renamed} ->
        send(self(), {__MODULE__, :renamed})
        assign(socket, :renaming, nil)

      {:error, reason} ->
        update(socket, :renaming, &%{&1 | error: rename_error(reason)})
    end
  end

  defp rename_error(:taken), do: gettext("Another tag is called that already.")
  defp rename_error(:blank), do: gettext("A tag needs a name.")
  defp rename_error(:not_found), do: gettext("This tag is no longer there.")

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.confirm_dialog
        :if={@renaming}
        name="rename-tag"
        title={gettext("Rename %{name}", name: @renaming.tag.name)}
        confirm_label={gettext("Rename")}
        target={@myself}
      >
        <form
          id="rename-tag-form"
          phx-change="rename_options"
          phx-submit="submit_rename_tag"
          phx-target={@myself}
          class="flex flex-col gap-2"
        >
          <input
            type="text"
            name="name"
            value={@renaming.name}
            maxlength="40"
            aria-label={gettext("Name")}
            class={dialog_field()}
          />
          <p :if={@renaming.error} class="text-label text-danger">{@renaming.error}</p>
        </form>
      </.confirm_dialog>
      <.confirm_dialog
        :if={@deleting}
        name="delete-tag"
        title={gettext("Delete %{name}?", name: @deleting.name)}
        confirm_label={gettext("Delete tag")}
        variant="danger"
        target={@myself}
      >
        <p>{gettext("The subscriptions stay; only the tag goes.")}</p>
      </.confirm_dialog>
    </div>
    """
  end
end
