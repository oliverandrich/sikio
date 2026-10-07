# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SubscriptionSettings do
  @moduledoc """
  LiveComponent with the edit and unsubscribe dialogs for one subscription.
  The edit dialog sets the name, delivery target, Shorts for YouTube channels and tags.

  The parent opens it with `send_update/2` and `open: {:edit, subscription, trigger}` or
  `open: {:leave, subscription, trigger}`. `trigger` is the DOM id refocused on cancel.
  `open: :close` closes it. The subscription must have its feed preloaded.
  The parent process then receives `{#{inspect(__MODULE__)}, :saved}`, `:left` or `:not_found`.
  """
  use SikioWeb, :live_component

  import SikioWeb.MediaComponents, only: [source_name: 1]

  alias Sikio.Library
  alias Sikio.Tags

  @impl true
  def mount(socket), do: {:ok, assign(socket, editing: nil, unsubscribing: nil, trigger: nil)}

  @impl true
  def update(%{open: {:edit, subscription, trigger}}, socket) do
    tags = Tags.of(socket.assigns.current_account, subscription.id)

    {:ok,
     assign(socket,
       trigger: trigger,
       editing: %{
         subscription: subscription,
         name: subscription.name || "",
         delivery: Atom.to_string(subscription.delivery),
         shorts: subscription.shorts,
         chosen: Enum.map(tags, & &1.name),
         new: ""
       }
     )}
  end

  def update(%{open: :close}, socket), do: {:ok, assign(socket, editing: nil, unsubscribing: nil)}

  def update(%{open: {:leave, subscription, trigger}}, socket),
    do: {:ok, assign(socket, trigger: trigger, unsubscribing: subscription, editing: nil)}

  def update(assigns, socket),
    do: {:ok, assign(socket, Map.take(assigns, [:id, :current_account, :tags]))}

  @impl true
  def handle_event("subscription_options", params, socket) do
    editing = %{
      socket.assigns.editing
      | name: params["name"] || "",
        delivery: params["delivery"] || socket.assigns.editing.delivery,
        shorts: shorts(params, socket.assigns.editing.shorts),
        chosen: params["tags"] || [],
        new: params["new"] || ""
    }

    {:noreply, assign(socket, :editing, editing)}
  end

  # Enter in a field submits the form. It saves the current values like the Save button.
  def handle_event("submit_edit_subscription", params, socket) do
    {:noreply, socket} = handle_event("subscription_options", params, socket)
    handle_event("confirm_edit_subscription", %{}, socket)
  end

  def handle_event("cancel_edit_subscription", _params, socket),
    do: {:noreply, socket |> assign(:editing, nil) |> give_back_focus()}

  # Ignores a repeated click that arrives after the first closed the dialog.
  def handle_event("confirm_edit_subscription", _params, %{assigns: %{editing: nil}} = socket),
    do: {:noreply, socket}

  # The `new` field may hold several comma-separated tags.
  def handle_event("confirm_edit_subscription", _params, socket) do
    %{subscription: subscription, chosen: chosen, new: new} = editing = socket.assigns.editing
    account = socket.assigns.current_account
    settings = Map.take(editing, [:name, :delivery, :shorts])

    case Library.update_subscription(account, subscription.id, settings) do
      {:ok, _} ->
        Tags.set(account, subscription.id, chosen ++ String.split(new, ","))
        send(self(), {__MODULE__, :saved})

      _ ->
        send(self(), {__MODULE__, :not_found})
    end

    {:noreply, assign(socket, :editing, nil)}
  end

  # Ignores a repeated click that arrives after the first opened the confirmation.
  def handle_event("unsubscribe", _params, %{assigns: %{editing: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("unsubscribe", _params, socket),
    do:
      {:noreply, assign(socket, unsubscribing: socket.assigns.editing.subscription, editing: nil)}

  def handle_event("cancel_unsubscribe", _params, socket),
    do: {:noreply, socket |> assign(:unsubscribing, nil) |> give_back_focus()}

  def handle_event("confirm_unsubscribe", _params, %{assigns: %{unsubscribing: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_unsubscribe", _params, socket) do
    case Library.unsubscribe(socket.assigns.current_account, socket.assigns.unsubscribing.id) do
      {:ok, _} -> send(self(), {__MODULE__, :left})
      _ -> send(self(), {__MODULE__, :not_found})
    end

    {:noreply, assign(socket, :unsubscribing, nil)}
  end

  # Only YouTube channel forms have the checkbox.
  # When unchecked, the browser sends the preceding hidden field's "false".
  defp shorts(%{"shorts" => value}, _current), do: value == "true"
  defp shorts(_params, current), do: current

  defp give_back_focus(%{assigns: %{trigger: nil}} = socket), do: socket
  defp give_back_focus(socket), do: push_event(socket, "focus", %{id: socket.assigns.trigger})

  defp deliveries,
    do: [
      {"inbox", gettext("The inbox")},
      {"queue", gettext("The end of the queue")},
      {"skip", gettext("The archive, unheard")}
    ]

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <.confirm_dialog
        :if={@editing}
        name="edit-subscription"
        title={source_name(@editing.subscription)}
        confirm_label={gettext("Save")}
        target={@myself}
        wide
      >
        <form
          id="subscription-form"
          phx-change="subscription_options"
          phx-submit="submit_edit_subscription"
          phx-target={@myself}
          class="flex flex-col gap-5"
        >
          <label class="flex flex-col gap-1.5 text-label font-semibold text-ink">
            {gettext("Name")}
            <input
              type="text"
              name="name"
              value={@editing.name}
              maxlength="200"
              placeholder={@editing.subscription.feed.title}
              class={[dialog_field(), "font-normal"]}
            />
          </label>
          <fieldset class="flex flex-col gap-2">
            <legend class="mb-1.5 text-label font-semibold text-ink">
              {gettext("New episodes go to")}
            </legend>
            <label
              :for={{value, label} <- deliveries()}
              class="flex items-center gap-2.5 text-label text-ink"
            >
              <input
                type="radio"
                name="delivery"
                value={value}
                checked={@editing.delivery == value}
                class="size-4 accent-accent"
              />
              {label}
            </label>
          </fieldset>
          <label
            :if={Sikio.Feeds.Feed.channel?(@editing.subscription.feed)}
            class="flex items-center gap-2.5 text-label text-ink"
          >
            <input type="hidden" name="shorts" value="false" />
            <input
              type="checkbox"
              name="shorts"
              value="true"
              checked={@editing.shorts}
              class="size-4 accent-accent"
            />
            {gettext("Show Shorts")}
          </label>
          <fieldset class="flex flex-col gap-2">
            <legend class="mb-1.5 text-label font-semibold text-ink">{gettext("Tags")}</legend>
            <input type="hidden" name="tags[]" value="" />
            <label :for={tag <- @tags} class="flex items-center gap-2.5 text-label text-ink">
              <input
                type="checkbox"
                name="tags[]"
                value={tag.name}
                checked={tag.name in @editing.chosen}
                class="size-4 accent-accent"
              />
              {tag.name}
            </label>
            <input
              type="text"
              name="new"
              value={@editing.new}
              maxlength="80"
              placeholder={gettext("New tag, or several set apart by commas")}
              aria-label={gettext("New tag")}
              class={[dialog_field(), "mt-1"]}
            />
          </fieldset>
        </form>
        <%!-- Unsubscribe opens a separate confirmation dialog. --%>
        <:aside>
          <button
            id="unsubscribe"
            type="button"
            phx-click="unsubscribe"
            phx-target={@myself}
            class="inline-flex min-h-11 cursor-pointer items-center gap-2 text-sm font-semibold text-danger hover:underline sm:min-h-9"
          >
            <Lucideicons.unplug aria-hidden="true" class="size-4" />
            {gettext("Unsubscribe")}
          </button>
        </:aside>
      </.confirm_dialog>
      <.confirm_dialog
        :if={@unsubscribing}
        name="unsubscribe"
        title={gettext("Unsubscribe from %{title}?", title: source_name(@unsubscribing))}
        confirm_label={gettext("Unsubscribe")}
        variant="danger"
        target={@myself}
      >
        <p>
          {gettext("Its items leave your library. Your progress stays, should you subscribe again.")}
        </p>
      </.confirm_dialog>
    </div>
    """
  end
end
