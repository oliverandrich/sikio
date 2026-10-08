# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Hub do
  @moduledoc """
  WebSub subscriptions of YouTube feeds at Google's hub.

  YouTube's feeds name no hub. Google documents its hub and a topic URL per channel instead.
  PeerTube offers no hub, and podcasts are not covered, so those feeds keep polling.
  A shared feed has one subscription, whatever the number of accounts that follow it.
  """
  import Ecto.Query

  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Hub.Subscription
  alias Sikio.Library.Subscription, as: Following
  alias Sikio.Repo

  @hub "https://pubsubhubbub.appspot.com/subscribe"
  # Ten days, the spec's suggested default. The hub grants its own lease when it verifies.
  @lease_seconds 864_000
  # A pending subscription is asked again after a day. An unreachable callback never verifies.
  @retry_seconds 86_400

  @doc "Returns the topic URL of a YouTube channel feed at Google's hub."
  def topic(%Feed{} = feed),
    do: "https://www.youtube.com/xml/feeds/videos.xml?channel_id=" <> Feed.channel_id(feed)

  @doc """
  Returns the feed's subscription, creating a pending one with a new token and secret.
  Returns `{:error, :unsupported}` for a feed that is not a YouTube channel.
  """
  def ensure(%Feed{id: feed_id} = feed) do
    if Feed.channel?(feed) do
      Repo.insert(
        %Subscription{feed_id: feed_id, token: random(), secret: random()},
        on_conflict: :nothing,
        conflict_target: :feed_id
      )

      {:ok, Repo.get_by!(Subscription, feed_id: feed_id)}
    else
      {:error, :unsupported}
    end
  end

  # 32 random bytes, URL-safe, so a token is a path segment and cannot be guessed.
  defp random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  Asks the hub to subscribe `subscription`'s feed with the callback `callback_base <> token`.
  The hub answers at once and verifies the callback later. Returns the subscription with
  `requested_at` set, or `{:error, :unavailable}`.
  """
  def request(%Subscription{} = subscription, callback_base, now \\ DateTime.utc_now()) do
    feed = subscription |> Repo.preload(:feed) |> Map.fetch!(:feed)

    form = %{
      "hub.mode" => "subscribe",
      "hub.topic" => topic(feed),
      "hub.callback" => callback_base <> subscription.token,
      "hub.secret" => subscription.secret,
      "hub.lease_seconds" => Integer.to_string(@lease_seconds)
    }

    case HTTP.post(@hub, form) do
      {:ok, %{status: status}} when status in 200..299 ->
        subscription |> Ecto.Changeset.change(requested_at: now) |> Repo.update()

      _failed ->
        {:error, :unavailable}
    end
  end

  @doc """
  Brings the subscriptions in line with the followed YouTube feeds and asks the hub for those
  due. Returns the subscriptions it asked for.

  Unfollowed feeds lose their subscription. A later push to its token is refused.
  A lapsed lease makes a subscription pending again. Pending ones are asked again after a day,
  active ones at four fifths of their lease. A denial is final. `enabled: false` does nothing.
  """
  def sync(now, callback_base, opts \\ []) do
    if Keyword.get(opts, :enabled, enabled?()) do
      prune(now)
      request_due(now, callback_base)
    else
      []
    end
  end

  # Drops subscriptions nobody follows, lapses expired leases and adds missing subscriptions.
  defp prune(now) do
    Repo.delete_all(from s in Subscription, where: s.feed_id not in subquery(followed()))

    Repo.update_all(
      from(s in Subscription, where: s.state == :active and s.lease_expires_at < ^now),
      set: [state: :pending]
    )

    # Channel feeds only: a YouTube playlist feed has no topic at the hub.
    missing =
      Repo.all(
        from f in Feed,
          left_join: s in Subscription,
          on: s.feed_id == f.id,
          where: f.kind == :youtube and like(f.url, "%channel_id=%"),
          where: f.id in subquery(followed()) and is_nil(s.id),
          select: f.id
      )

    Repo.insert_all(
      Subscription,
      Enum.map(
        missing,
        &%{feed_id: &1, token: random(), secret: random(), inserted_at: now, updated_at: now}
      ),
      on_conflict: :nothing,
      conflict_target: :feed_id
    )
  end

  defp request_due(now, callback_base) do
    retry = DateTime.add(now, -@retry_seconds)

    from(s in Subscription,
      where:
        (s.state == :pending and (is_nil(s.requested_at) or s.requested_at <= ^retry)) or
          (s.state == :active and s.renew_at <= ^now and
             (is_nil(s.requested_at) or s.requested_at < s.renew_at))
    )
    |> preload(:feed)
    |> Repo.all()
    |> Enum.flat_map(fn subscription ->
      case request(subscription, callback_base, now) do
        {:ok, requested} -> [requested]
        {:error, _reason} -> []
      end
    end)
  end

  @doc "Whether the instance subscribes at hubs. `SIKIO_WEBSUB=false` turns it off."
  def enabled?, do: Application.get_env(:sikio, :websub, true)

  defp followed, do: from(f in Following, where: not f.paused, select: f.feed_id)
end
