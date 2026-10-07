# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.Events do
  @moduledoc """
  Account-scoped PubSub broadcasts for open media views.

  Each account has two topics. `library:<id>` carries the account's own changes, such as
  progress and removals, to its open tabs. `inbox:<id>` carries `:library_changed` after a feed
  update. `feed_updated/1` broadcasts it to every account subscribed to the feed.
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
