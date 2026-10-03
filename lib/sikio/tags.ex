# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Tags do
  @moduledoc """
  An account's own tags on its own subscriptions.

  A subscription may carry several tags or none. Tags hang on subscriptions, which belong to an
  account, so the feeds beneath stay shared and know nothing of them. A tag is made where it is
  first given and stays when its last subscription lets go of it, until it is deleted.
  """
  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Library.Events
  alias Sikio.Library.Subscription
  alias Sikio.Repo
  alias Sikio.Tags.SubscriptionTag
  alias Sikio.Tags.Tag

  @longest 40

  @doc "The account's tags, in the order of their names."
  def list(%User{id: user_id}),
    do: Repo.all(from t in Tag, where: t.user_id == ^user_id, order_by: t.key)

  @doc "Each of the account's tags with the feeds its subscriptions follow: `%{tag_id => [feed_id]}`."
  def feeds(%User{id: user_id}) do
    Repo.all(
      from t in Tag,
        left_join: st in SubscriptionTag,
        on: st.tag_id == t.id,
        left_join: s in Subscription,
        on: s.id == st.subscription_id and s.user_id == ^user_id,
        where: t.user_id == ^user_id,
        select: {t.id, s.feed_id}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {tag, feeds} -> {tag, Enum.reject(feeds, &is_nil/1)} end)
  end

  @doc "The feeds the account's tag `id` gathers, as a query to use inside another."
  def feed_ids(%User{id: user_id}, id) do
    from s in Subscription,
      join: st in SubscriptionTag,
      on: st.subscription_id == s.id,
      join: t in Tag,
      on: t.id == st.tag_id and t.user_id == ^user_id,
      where: s.user_id == ^user_id and t.id == ^cast_id(id),
      select: s.feed_id
  end

  @doc "The tags the account's subscription `id` carries, or none for a subscription not its own."
  def of(%User{id: user_id}, id) do
    Repo.all(
      from t in Tag,
        join: st in SubscriptionTag,
        on: st.tag_id == t.id,
        join: s in Subscription,
        on: s.id == st.subscription_id and s.user_id == ^user_id,
        where: t.user_id == ^user_id and s.id == ^cast_id(id),
        order_by: t.key
    )
  end

  @doc """
  Gives the account's subscription `id` exactly the tags `names` names, making those it has not
  named before. Answers the tags, or `{:error, :not_found}` for a subscription not its own. The
  account's views hear of it as `{:tags_changed, subscription_id}`.
  """
  def set(%User{id: user_id} = account, id, names) do
    case Repo.get_by(Subscription, id: cast_id(id), user_id: user_id) do
      nil ->
        {:error, :not_found}

      subscription ->
        account
        |> tag(subscription, names)
        |> tap(fn _ -> Events.broadcast(account, {:tags_changed, subscription.id}) end)
    end
  end

  defp tag(account, subscription, names) do
    Repo.transaction(fn ->
      tags = names |> cleaned() |> Enum.map(&named(account, &1))
      ids = Enum.map(tags, & &1.id)

      Repo.delete_all(
        from st in SubscriptionTag,
          where: st.subscription_id == ^subscription.id and st.tag_id not in ^ids
      )

      Repo.insert_all(
        SubscriptionTag,
        Enum.map(ids, &%{subscription_id: subscription.id, tag_id: &1}),
        on_conflict: :nothing
      )

      Enum.sort_by(tags, & &1.key)
    end)
  end

  @doc "Adds the tags `names` names to the account's subscription `id`, beside those it carries."
  def add(account, id, []), do: {:ok, of(account, id)}
  def add(account, id, names), do: set(account, id, Enum.map(of(account, id), & &1.name) ++ names)

  @doc """
  Gives the account's tag `id` a new name. Answers the tag, or `{:error, :blank}`, `{:error,
  :taken}` for a name another of its tags holds, or `{:error, :not_found}`.
  """
  def rename(%User{id: user_id} = account, id, name) do
    case {Repo.get_by(Tag, id: cast_id(id), user_id: user_id), cleaned([name])} do
      {nil, _name} ->
        {:error, :not_found}

      {_tag, []} ->
        {:error, :blank}

      {tag, [name]} ->
        if taken?(user_id, String.downcase(name), tag.id),
          do: {:error, :taken},
          else: named_anew(account, tag, name)
    end
  end

  defp named_anew(account, tag, name) do
    tag
    |> Ecto.Changeset.change(name: name, key: String.downcase(name))
    |> Repo.update()
    |> tap(fn _ -> Events.broadcast(account, {:tags_changed, nil}) end)
  end

  @doc "Deletes the account's tag `id`. Its subscriptions stay; only the tag leaves them."
  def delete(%User{id: user_id} = account, id) do
    case Repo.get_by(Tag, id: cast_id(id), user_id: user_id) do
      nil ->
        {:error, :not_found}

      tag ->
        tag
        |> Repo.delete()
        |> tap(fn _ -> Events.broadcast(account, {:tags_changed, nil}) end)
    end
  end

  defp taken?(user_id, key, id),
    do:
      Repo.exists?(from t in Tag, where: t.user_id == ^user_id and t.key == ^key and t.id != ^id)

  # Names as typed: trimmed, short enough, none empty, each once in whatever letters.
  defp cleaned(names) do
    names
    |> Enum.map(&(&1 |> String.trim() |> String.slice(0, @longest)))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp named(%User{id: user_id}, name) do
    key = String.downcase(name)
    now = DateTime.utc_now()

    Repo.insert_all(
      Tag,
      [%{user_id: user_id, name: name, key: key, inserted_at: now, updated_at: now}],
      on_conflict: :nothing,
      conflict_target: [:user_id, :key]
    )

    Repo.get_by!(Tag, user_id: user_id, key: key)
  end

  defp cast_id(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} -> id
      _ -> -1
    end
  end
end
