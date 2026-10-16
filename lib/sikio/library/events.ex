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

  def subscribe_updates(%User{} = account),
    do: Phoenix.PubSub.subscribe(Sikio.PubSub, inbox(account))

  @doc "Subscribes the caller to the end of the account's library imports."
  def subscribe_imports(%User{id: id}),
    do: Phoenix.PubSub.subscribe(Sikio.PubSub, "transfer:#{id}")

  @doc """
  Sends `{:library_imported, result}` to the import page only, where `result` is
  `{:ok, summary}` or `:error`. Pages that follow the library topic have no clause for it.
  """
  def imported(%User{id: id}, result),
    do: Phoenix.PubSub.broadcast(Sikio.PubSub, "transfer:#{id}", {:library_imported, result})

  @doc "Tells the account's open lists to reload, as a feed update does."
  def changed(%User{} = account),
    do: Phoenix.PubSub.broadcast(Sikio.PubSub, inbox(account), :library_changed)

  def feed_updated(feed_id) do
    Repo.all(from s in Subscription, where: s.feed_id == ^feed_id, select: s.user_id)
    |> Enum.each(&changed(%User{id: &1}))
  end

  defp topic(id), do: "library:#{id}"
  defp inbox(%User{id: id}), do: "inbox:#{id}"
end
