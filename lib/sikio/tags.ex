# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Tags do
  @moduledoc """
  Account-scoped tags on the account's subscriptions.

  A subscription has zero or more tags. Tags attach to subscriptions, not to the shared feeds.
  A tag is created on first use. It persists without subscriptions until it is deleted.
  """
  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Library.Events
  alias Sikio.Library.Subscription
  alias Sikio.Repo
  alias Sikio.Tags.SubscriptionTag
  alias Sikio.Tags.Tag

  @longest 40

  @doc "Returns the account's tags, sorted case-insensitively by name."
  def list(%User{id: user_id}),
    do: Repo.all(from t in Tag, where: t.user_id == ^user_id, order_by: t.key)

  @doc "Returns each of the account's tags with its feeds: `%{tag_id => [feed_id]}`."
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

  @doc "Returns a query for the feed ids tagged `id`, for use as a subquery."
  def feed_ids(%User{id: user_id}, id) do
    from s in Subscription,
      join: st in SubscriptionTag,
      on: st.subscription_id == s.id,
      join: t in Tag,
      on: t.id == st.tag_id and t.user_id == ^user_id,
      where: s.user_id == ^user_id and t.id == ^cast_id(id),
      select: s.feed_id
  end

  @doc "Returns the tags on subscription `id`, or `[]` for another account's subscription."
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
  Replaces the tags on subscription `id` with `names`, creating missing tags.
  Returns `{:ok, tags}`, or `{:error, :not_found}` for another account's subscription.
  Broadcasts `{:tags_changed, subscription_id}` to the account.
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

  @doc "Adds the tags `names` to subscription `id`, keeping its current tags."
  def add(account, id, []), do: {:ok, of(account, id)}
  def add(account, id, names), do: set(account, id, Enum.map(of(account, id), & &1.name) ++ names)

  @doc """
  Renames the account's tag `id`.
  Returns `{:ok, tag}`, `{:error, :blank}` or `{:error, :not_found}`.
  Returns `{:error, :taken}` when another of the account's tags has the name.
  Broadcasts `{:tags_changed, nil}` to the account on success.
  """
  def rename(%User{id: user_id} = account, id, name) do
    case {Repo.get_by(Tag, id: cast_id(id), user_id: user_id), cleaned([name])} do
      {nil, _name} ->
        {:error, :not_found}

      {_tag, []} ->
        {:error, :blank}

      {tag, [name]} ->
        named_anew(account, tag, name)
    end
  end

  # The unique index on `[:user_id, :key]` rejects duplicates.
  # Two concurrent renames to one name therefore cannot both succeed.
  defp named_anew(account, tag, name) do
    tag
    |> Ecto.Changeset.change(name: name, key: String.downcase(name))
    |> Ecto.Changeset.unique_constraint([:user_id, :key])
    |> Repo.update()
    |> case do
      {:ok, tag} ->
        Events.broadcast(account, {:tags_changed, nil})
        {:ok, tag}

      {:error, _changeset} ->
        {:error, :taken}
    end
  end

  @doc "Deletes the account's tag `id`. Its subscriptions remain without the tag."
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

  # Trims names, caps them at 40 characters, drops blanks and case-insensitive duplicates.
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
