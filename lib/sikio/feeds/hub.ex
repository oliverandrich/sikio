# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Hub do
  @moduledoc """
  WebSub subscriptions of YouTube feeds at Google's hub.

  YouTube's feeds name no hub. Google documents its hub and a topic URL per channel instead.
  PeerTube offers no hub, and podcasts are not covered, so those feeds keep polling.
  A shared feed has one subscription, whatever the number of accounts that follow it.
  """
  import Ecto.Query

  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Hub.Subscription
  alias Sikio.Library.Subscription, as: Following
  alias Sikio.Repo

  @hub "https://pubsubhubbub.appspot.com/subscribe"
  # Ten days, the spec's suggested default. The hub grants its own lease when it verifies.
  @lease_seconds 864_000
  # The longest lease taken from a hub, so a wild value cannot overflow a timestamp.
  @max_lease_seconds 30 * 86_400
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

  @doc """
  Activates the subscription with `token` when the hub verifies it for its own topic.
  The lease starts now, and `renew_at` is four fifths into it. Without a lease the hub gets ten
  days, and at most thirty count. A denied subscription stays denied. Returns `:error` otherwise.
  """
  def verify(token, topic, lease_seconds, now \\ DateTime.utc_now()) do
    lease_seconds = min(lease_seconds || @lease_seconds, @max_lease_seconds)

    case for_topic(token, topic) do
      %Subscription{state: state} = subscription when state != :denied ->
        subscription
        |> Ecto.Changeset.change(
          state: :active,
          verified_at: now,
          lease_expires_at: DateTime.add(now, lease_seconds),
          renew_at: DateTime.add(now, div(lease_seconds * 4, 5))
        )
        |> Repo.update()

      _refused ->
        :error
    end
  end

  @doc "Marks the subscription with `token` denied when the hub refuses its topic."
  def deny(token, topic) do
    case for_topic(token, topic) do
      nil -> :error
      subscription -> subscription |> Ecto.Changeset.change(state: :denied) |> Repo.update()
    end
  end

  @doc "Returns the subscription with `token`, or nil."
  def by_token(token) when is_binary(token), do: Repo.get_by(Subscription, token: token)

  @doc """
  Whether `signature`, the `X-Hub-Signature` header, signs `body` with the subscription's secret.
  The header names its algorithm: sha1, sha256, sha384 or sha512.
  """
  def authentic?(%Subscription{secret: secret}, signature, body) do
    with [method, hex] <- String.split(signature || "", "=", parts: 2),
         {:ok, alg} <- algorithm(method),
         {:ok, given} <- Base.decode16(hex, case: :mixed) do
      Plug.Crypto.secure_compare(:crypto.mac(:hmac, alg, secret, body), given)
    else
      _invalid -> false
    end
  end

  defp algorithm("sha1"), do: {:ok, :sha}
  defp algorithm("sha256"), do: {:ok, :sha256}
  defp algorithm("sha384"), do: {:ok, :sha384}
  defp algorithm("sha512"), do: {:ok, :sha512}
  defp algorithm(_method), do: :error

  # A verification names the topic it is for. Another topic is not this subscription's request.
  defp for_topic(token, topic) do
    with %Subscription{} = subscription <- by_token(token),
         %Feed{} = feed <- Repo.get(Feed, subscription.feed_id),
         true <- topic == topic(feed) do
      subscription
    else
      _other -> nil
    end
  end

  @doc """
  Records the video a push announced and brings the feed's next check forward.
  The scheduler then refreshes the feed, also while a refresh of it is running.
  """
  def announce(%Subscription{} = subscription, video_id, now \\ DateTime.utc_now()) do
    Repo.update_all(from(f in Feed, where: f.id == ^subscription.feed_id),
      set: [next_check_at: now]
    )

    subscription |> Ecto.Changeset.change(awaiting: video_id) |> Repo.update()
  end

  @doc """
  Returns how often the feed polls: `:live` once a day, since its hub announces new videos;
  `:awaiting` at the base interval, since an announced video is not stored yet; `:polling` as
  usual, without an active, unexpired subscription or with the hub turned off.
  """
  def pace(feed_id, opts \\ []) do
    now = DateTime.utc_now()

    awaiting =
      Repo.one(
        from s in Subscription,
          where: s.feed_id == ^feed_id and s.state == :active and s.lease_expires_at > ^now,
          select: {s.id, s.awaiting}
      )

    cond do
      not Keyword.get(opts, :enabled, enabled?()) or is_nil(awaiting) -> :polling
      stored?(feed_id, elem(awaiting, 1)) -> :live
      true -> :awaiting
    end
  end

  defp stored?(_feed_id, nil), do: true

  defp stored?(feed_id, video_id) do
    external_id = "yt:video:" <> video_id
    Repo.exists?(from e in Entry, where: e.feed_id == ^feed_id and e.external_id == ^external_id)
  end
end
