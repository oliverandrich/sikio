# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SubscriptionSettings do
  @moduledoc """
  LiveComponent with the edit and unsubscribe dialogs for one subscription.
  The edit dialog sets the name, delivery target, Shorts for YouTube channels and tags.

  The parent opens it with `send_update/2` and `open: {:edit, subscription, trigger}` or
  `open: {:leave, subscription, trigger}`. `trigger` is the DOM id refocused on cancel.
  `open: :close` closes it. The subscription must have its feed preloaded.
  The parent process then receives `{#{inspect(__MODULE__)}, :saved}`, `:left` or `:not_found`.

  For an administrator, the edit dialog also removes the feed for everyone, after a confirmation
  that names what goes with it. The parent then receives `{:removed, message}` or
  `{:refused, message}` and shows the message, which a component's flash cannot do without a
  navigation.
  """
  use SikioWeb, :live_component

  import SikioWeb.MediaComponents, only: [source_name: 1]

  alias Sikio.Library
  alias Sikio.Removals
  alias Sikio.Tags

  @impl true
  def mount(socket),
    do: {:ok, assign(socket, editing: nil, unsubscribing: nil, removing: nil, trigger: nil)}

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
         new: "",
         errors: []
       }
     )}
  end

  def update(%{open: :close}, socket),
    do: {:ok, assign(socket, editing: nil, unsubscribing: nil, removing: nil)}

  def update(%{open: {:leave, subscription, trigger}}, socket),
    do: {:ok, assign(socket, trigger: trigger, unsubscribing: subscription, editing: nil)}

  def update(assigns, socket),
    do: {:ok, assign(socket, Map.take(assigns, [:id, :current_account, :tags]))}

  @impl true
  def handle_event("subscription_options", params, socket),
    do: {:noreply, take_options(socket, params)}

  # Enter in a field submits the form. It saves the current values like the Save button.
  def handle_event("submit_edit_subscription", params, socket),
    do: {:noreply, socket |> take_options(params) |> save()}

  def handle_event("cancel_edit_subscription", _params, socket),
    do: {:noreply, socket |> assign(:editing, nil) |> give_back_focus()}

  def handle_event("confirm_edit_subscription", _params, socket), do: {:noreply, save(socket)}

  # Ignores a repeated click that arrives after the first opened the confirmation.
  def handle_event("unsubscribe", _params, %{assigns: %{editing: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("unsubscribe", _params, socket),
    do:
      {:noreply, assign(socket, unsubscribing: socket.assigns.editing.subscription, editing: nil)}

  # The button shows only to administrators. The counts are theirs alone, so `feed_removal/2`
  # checks the stored role before the confirmation opens.
  def handle_event(
        "remove_feed",
        _params,
        %{assigns: %{editing: %{subscription: subscription}}} = socket
      ) do
    case Removals.feed_removal(socket.assigns.current_account, subscription.feed_id) do
      {:ok, removal} ->
        {:noreply,
         assign(socket, removing: Map.put(removal, :subscription, subscription), editing: nil)}

      {:error, _forbidden} ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_feed", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_remove_feed", _params, socket),
    do: {:noreply, socket |> assign(:removing, nil) |> give_back_focus()}

  def handle_event("confirm_remove_feed", _params, %{assigns: %{removing: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_remove_feed", _params, socket) do
    subscription = socket.assigns.removing.subscription
    name = source_name(subscription)

    message =
      case Removals.remove_feed(socket.assigns.current_account, subscription.feed_id) do
        {:ok, _feed} ->
          {:removed, gettext("Removed %{title} for everyone.", title: name)}

        {:error, :forbidden} ->
          {:refused, gettext("Only administrators can remove a feed for everyone.")}

        {:error, _gone} ->
          :not_found
      end

    send(self(), {__MODULE__, message})
    {:noreply, assign(socket, :removing, nil)}
  end

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

  # A changed field drops the errors of the last save. The next save checks again.
  defp take_options(socket, params) do
    editing = socket.assigns.editing

    taken = %{
      editing
      | name: params["name"] || "",
        delivery: params["delivery"] || editing.delivery,
        shorts: shorts(params, editing.shorts),
        chosen: params["tags"] || [],
        new: params["new"] || ""
    }

    errors = Enum.filter(editing.errors, fn {field, _} -> taken[field] == editing[field] end)
    assign(socket, :editing, %{taken | errors: errors})
  end

  # Ignores a repeated click that arrives after the first closed the dialog.
  # Invalid settings keep the dialog open with their errors. The `new` field may hold several
  # comma-separated tags.
  defp save(%{assigns: %{editing: nil}} = socket), do: socket

  defp save(socket) do
    %{subscription: subscription, chosen: chosen, new: new} = editing = socket.assigns.editing
    settings = Map.take(editing, [:name, :delivery, :shorts])
    tags = chosen ++ String.split(new, ",")

    case Library.configure(socket.assigns.current_account, subscription.id, settings, tags) do
      {:ok, _} ->
        send(self(), {__MODULE__, :saved})
        assign(socket, :editing, nil)

      {:error, %Ecto.Changeset{errors: errors}} ->
        assign(socket, :editing, %{editing | errors: errors})

      {:error, :not_found} ->
        send(self(), {__MODULE__, :not_found})
        assign(socket, :editing, nil)
    end
  end

  # Only YouTube channel forms have the checkbox.
  # When unchecked, the browser sends the preceding hidden field's "false".
  defp shorts(%{"shorts" => value}, _current), do: value == "true"
  defp shorts(_params, current), do: current

  # One element per field, so `aria-describedby` names a unique id.
  attr :errors, :list, required: true
  attr :field, :atom, required: true

  defp field_error(assigns) do
    ~H"""
    <.error :if={@errors[@field]} id={error_id(@field)}>
      {Enum.join(translate_errors(@errors, @field), " ")}
    </.error>
    """
  end

  defp error_id(field), do: "subscription-#{field}-error"

  defp give_back_focus(%{assigns: %{trigger: nil}} = socket), do: socket
  defp give_back_focus(socket), do: push_event(socket, "focus", %{id: socket.assigns.trigger})

  @doc "Returns the places new entries can go, as `{delivery, label}`."
  def deliveries,
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
          <div>
            <label class="flex flex-col gap-1.5 text-label font-semibold text-ink">
              {gettext("Name")}
              <input
                type="text"
                name="name"
                value={@editing.name}
                maxlength="200"
                placeholder={@editing.subscription.feed.title}
                aria-invalid={@editing.errors[:name] && "true"}
                aria-describedby={@editing.errors[:name] && error_id(:name)}
                class={[dialog_field(), "font-normal"]}
              />
            </label>
            <.field_error errors={@editing.errors} field={:name} />
          </div>
          <.radio_group
            name="delivery"
            legend={gettext("New episodes go to")}
            options={deliveries()}
            value={@editing.delivery}
            aria-describedby={@editing.errors[:delivery] && error_id(:delivery)}
          >
            <.field_error errors={@editing.errors} field={:delivery} />
          </.radio_group>
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
          <div class="flex flex-wrap gap-x-5 gap-y-1">
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
            <button
              :if={@current_account.admin}
              id="remove-feed"
              type="button"
              phx-click="remove_feed"
              phx-target={@myself}
              class="inline-flex min-h-11 cursor-pointer items-center gap-2 text-sm font-semibold text-danger hover:underline sm:min-h-9"
            >
              <Lucideicons.trash_2 aria-hidden="true" class="size-4" />
              {gettext("Remove for everyone")}
            </button>
          </div>
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
      <.confirm_dialog
        :if={@removing}
        name="remove-feed"
        title={gettext("Remove %{title} for everyone?", title: source_name(@removing.subscription))}
        confirm_label={gettext("Remove for everyone")}
        variant="danger"
        target={@myself}
      >
        <p>
          {ngettext(
            "It is in 1 member's library.",
            "It is in %{count} members' libraries.",
            @removing.members
          )}
          {ngettext(
            "Its item leaves every library, with progress, favourites and saved items.",
            "Its %{count} items leave every library, with progress, favourites and saved items.",
            @removing.entries
          )}
        </p>
        <p class="mt-2">{gettext("Adding it again later starts afresh.")}</p>
      </.confirm_dialog>
    </div>
    """
  end
end
