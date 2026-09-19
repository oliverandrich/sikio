defmodule Sikio.Library.Events do
  @moduledoc """
  Account-scoped notifications for active media views.

  Two topics, because two things happen. A personal one carries what this account did, such as
  progress and removals, to its own open tabs. A per-account inbox carries the arrival of new
  episodes, which begins as one shared feed update and fans out to everybody subscribed to it.
  """
  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Library.Subscription
  alias Sikio.Repo

  def subscribe(%User{id: id}), do: Phoenix.PubSub.subscribe(Sikio.PubSub, topic(id))

  def broadcast(%User{id: id}, event),
    do: Phoenix.PubSub.broadcast(Sikio.PubSub, topic(id), event)

  def subscribe_updates(%User{id: id}),
    do: Phoenix.PubSub.subscribe(Sikio.PubSub, "inbox:#{id}")

  def feed_updated(feed_id) do
    Repo.all(from s in Subscription, where: s.feed_id == ^feed_id, select: s.user_id)
    |> Enum.each(fn id ->
      Phoenix.PubSub.broadcast(Sikio.PubSub, "inbox:#{id}", :library_changed)
    end)
  end

  defp topic(id), do: "library:#{id}"
end
