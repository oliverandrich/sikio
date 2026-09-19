defmodule Sikio.Library do
  @moduledoc """
  Account-scoped subscriptions and imported media.

  Every function here takes the account as its first argument, and every query is written against
  it rather than filtered afterwards. Feed content is shared; what an account subscribed to, and
  how far it got, is not.
  """
  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.Entry
  alias Sikio.Library.Events
  alias Sikio.Library.Subscription
  alias Sikio.Playback.State
  alias Sikio.Repo

  @doc """
  The one entry with this id that the account is allowed to see, or `nil`.

  This is the authorization for everything that follows, so it is asked again at each write rather
  than trusted from the request that started a player.
  """
  def entry(%User{id: user_id}, id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} -> Repo.one(from e in entry_query(user_id), where: e.id == ^id)
      _ -> nil
    end
  end

  def subscribe(%User{id: user_id}, preview) do
    result =
      Repo.transaction(fn ->
        with {:ok, feed} <- Feeds.store(preview),
             {:ok, subscription} <-
               Repo.insert(
                 Subscription.changeset(%Subscription{user_id: user_id, feed_id: feed.id}, %{}),
                 on_conflict: :nothing,
                 conflict_target: [:user_id, :feed_id]
               ) do
          load_subscription(subscription, user_id, feed.id)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, subscription} -> Events.feed_updated(subscription.feed_id)
      _ -> :ok
    end

    result
  end

  def subscriptions(%User{id: user_id}) do
    Repo.all(
      from s in Subscription,
        where: s.user_id == ^user_id,
        order_by: [desc: s.inserted_at, desc: s.id],
        preload: [:feed]
    )
  end

  def entries(%User{id: user_id}, filters \\ %{}) do
    Repo.all(
      from e in filtered_entries(user_id, filters),
        order_by: [desc_nulls_last: e.published_at, desc: e.id],
        limit: 100
    )
  end

  @doc """
  Reduces request parameters to the three filters, discarding anything else.

  Written here rather than in the view because the same values reach the database. An unrecognised
  value becomes an empty string, which means no filter, so a hand-edited URL narrows nothing.
  """
  def normalize_filters(params) do
    %{
      "kind" => choice(params["kind"], ~w(youtube podcast)),
      "status" => choice(params["status"], ~w(new in_progress completed)),
      "source" => source_id(params["source"])
    }
  end

  defp choice(value, values), do: if(value in values, do: value, else: "")

  defp source_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 -> Integer.to_string(id)
      _ -> ""
    end
  end

  defp source_id(_), do: ""

  defp filtered_entries(user_id, params) do
    filters = normalize_filters(params)
    query = entry_query(user_id)

    query =
      if filters["source"] == "",
        do: query,
        else: where(query, [e], e.feed_id == ^String.to_integer(filters["source"]))

    query =
      if filters["kind"] == "",
        do: query,
        else: where(query, [e, s, p, f], f.kind == ^filters["kind"])

    case filters["status"] do
      "" -> query
      # An entry nobody has opened has no row at all, which is the same thing as new.
      "new" -> where(query, [e, s, p], is_nil(p.id) or p.status == :new)
      status -> where(query, [e, s, p], p.status == ^status)
    end
  end

  # The join to subscriptions is what makes this account-scoped, and the left join carries this
  # account's progress onto the shared row.
  defp entry_query(user_id) do
    from e in Entry,
      join: s in Subscription,
      on: s.feed_id == e.feed_id and s.user_id == ^user_id,
      left_join: p in State,
      on: p.entry_id == e.id and p.user_id == ^user_id,
      join: f in assoc(e, :feed),
      select_merge: %{playback: p},
      # Bound to the join above. An unbound `preload: [:feed]` joins and then fetches the feeds a
      # second time, which every library page and every saved position would pay for.
      preload: [feed: f]
  end

  def pause(account, id, paused) when is_boolean(paused) do
    case owned(account, id) do
      nil -> {:error, :not_found}
      subscription -> subscription |> Subscription.changeset(%{paused: paused}) |> Repo.update()
    end
  end

  defp load_subscription(%Subscription{id: nil}, user_id, feed_id) do
    Repo.get_by!(Subscription, user_id: user_id, feed_id: feed_id) |> Repo.preload(:feed)
  end

  defp load_subscription(subscription, _user_id, _feed_id), do: Repo.preload(subscription, :feed)

  @doc """
  Removes one account's subscription, leaving the shared feed and its entries in place.

  Somebody else may still be subscribed, and this account may subscribe again later and find its
  progress where it left it.
  """
  def unsubscribe(account, id) do
    case owned(account, id) do
      nil ->
        {:error, :not_found}

      subscription ->
        result = Repo.delete(subscription)

        if match?({:ok, _}, result),
          do: Events.broadcast(account, {:subscription_removed, subscription.feed_id})

        result
    end
  end

  def active_feed_ids do
    Repo.all(from s in Subscription, where: not s.paused, select: s.feed_id, distinct: true)
  end

  def active_feed?(id),
    do: Repo.exists?(from s in Subscription, where: s.feed_id == ^id and not s.paused)

  defp owned(%User{id: user_id}, id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} -> Repo.get_by(Subscription, id: id, user_id: user_id)
      _ -> nil
    end
  end
end
