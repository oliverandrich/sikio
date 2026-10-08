# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.WebSubControllerTest do
  @moduledoc """
  The WebSub callback: the hub verifies a subscription with a GET and pushes new content with a
  signed POST. A push only triggers a refresh of its feed.
  """
  use SikioWeb.ConnCase, async: true

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.Hub
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Repo

  setup do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, video} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, sub} = Library.subscribe(user, video)
    feed = Repo.get!(Feed, sub.feed_id)
    {:ok, hub} = Hub.ensure(feed)
    %{feed: feed, hub: hub, path: "/websub/" <> hub.token}
  end

  defp verify(conn, path, params), do: get(conn, path <> "?" <> URI.encode_query(params))

  # The challenge echoes back, and the lease sets when to renew: at four fifths of it.
  test "the hub's verification activates the subscription for its lease", c do
    conn =
      verify(build_conn(), c.path, %{
        "hub.mode" => "subscribe",
        "hub.topic" => Hub.topic(c.feed),
        "hub.challenge" => "abc123",
        "hub.lease_seconds" => "432000"
      })

    assert response(conn, 200) == "abc123"
    sub = Repo.get!(Hub.Subscription, c.hub.id)
    assert sub.state == :active
    assert DateTime.diff(sub.lease_expires_at, sub.verified_at) == 432_000
    assert DateTime.diff(sub.renew_at, sub.verified_at) == 345_600
  end

  # Another topic or an unknown token is not this instance's request, so it is refused.
  test "a verification for another topic or token is refused", c do
    params = %{"hub.mode" => "subscribe", "hub.challenge" => "x", "hub.lease_seconds" => "10"}

    assert build_conn()
           |> verify(c.path, Map.put(params, "hub.topic", "https://evil.example/"))
           |> response(404)

    assert build_conn()
           |> verify("/websub/unknown", Map.put(params, "hub.topic", Hub.topic(c.feed)))
           |> response(404)

    assert Repo.get!(Hub.Subscription, c.hub.id).state == :pending
  end

  test "a denial marks the subscription denied", c do
    conn =
      verify(build_conn(), c.path, %{"hub.mode" => "denied", "hub.topic" => Hub.topic(c.feed)})

    assert response(conn, 200)
    assert Repo.get!(Hub.Subscription, c.hub.id).state == :denied
  end

  defp deliver(path, body, signature) do
    build_conn()
    |> put_req_header("content-type", "application/atom+xml")
    |> put_req_header("x-hub-signature", signature)
    |> post(path, body)
  end

  defp sign(secret, body, alg \\ :sha),
    do: Base.encode16(:crypto.mac(:hmac, alg, secret, body), case: :lower)

  @push ~s(<feed><entry><yt:videoId>zzzzzzzzzzz</yt:videoId></entry></feed>)

  defp verified(c) do
    {:ok, sub} = Hub.verify(c.hub.token, Hub.topic(c.feed), 864_000)
    sub
  end

  defp due_soon?(feed),
    do: DateTime.diff(Repo.get!(Feed, feed.id).next_check_at, DateTime.utc_now(), :second) <= 60

  # A signed push names the new video and brings the feed's next check forward. The scheduler
  # then refreshes it, also when a refresh of the feed is already running.
  test "a signed push brings the feed's check forward and awaits its video", c do
    verified(c)
    assert deliver(c.path, @push, "sha1=" <> sign(c.hub.secret, @push)) |> response(204)
    assert due_soon?(c.feed)
    assert Hub.pace(c.feed.id) == :awaiting
  end

  test "a push with a sha256 signature is accepted", c do
    verified(c)

    assert deliver(c.path, @push, "sha256=" <> sign(c.hub.secret, @push, :sha256))
           |> response(204)

    assert Hub.pace(c.feed.id) == :awaiting
  end

  # A wrong signature or an unverified subscription is acknowledged but ignored, as the spec
  # allows. A dropped token is gone, and an oversized body is no push.
  test "an unsigned, unverified or unknown push changes nothing", c do
    before = Repo.get!(Feed, c.feed.id).next_check_at
    assert deliver(c.path, @push, "sha1=" <> sign(c.hub.secret, @push)) |> response(204)

    verified(c)
    assert deliver(c.path, @push, "sha1=" <> sign("wrong", @push)) |> response(204)
    assert Repo.get!(Feed, c.feed.id).next_check_at == before
    assert Hub.pace(c.feed.id) == :live

    assert deliver("/websub/unknown", @push, "sha1=00") |> response(410)
    assert deliver(c.path, String.duplicate("a", 1_100_000), "sha1=00") |> response(413)
  end
end
