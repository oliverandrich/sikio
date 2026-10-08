# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.HubTest do
  @moduledoc """
  Tests the WebSub subscriptions of YouTube feeds: one per shared feed, with its own token and
  secret.
  """
  use Sikio.DataCase, async: true
  use Oban.Testing, repo: Sikio.Repo

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.Hub
  alias Sikio.Feeds.Parser
  alias Sikio.Library

  setup do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, video} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, podcast} = Parser.parse(podcast(), feed_url())
    {:ok, video_sub} = Library.subscribe(user, video)
    {:ok, podcast_sub} = Library.subscribe(user, podcast)
    %{youtube: Repo.get!(Feed, video_sub.feed_id), podcast: Repo.get!(Feed, podcast_sub.feed_id)}
  end

  # A shared feed has one subscription, so its token and secret stay the same.
  test "a YouTube feed gets one pending subscription with its own token and secret", c do
    assert {:ok, %{state: :pending, token: token, secret: secret} = first} = Hub.ensure(c.youtube)
    assert byte_size(token) >= 32 and byte_size(secret) >= 32
    assert {:ok, again} = Hub.ensure(c.youtube)
    assert again.id == first.id and again.token == token

    # Only YouTube names a hub. PeerTube and podcasts keep polling.
    assert {:error, :unsupported} = Hub.ensure(c.podcast)

    Repo.delete!(c.youtube)
    assert Repo.aggregate(Hub.Subscription, :count) == 0
  end

  test "the topic is the feed Google's hub documents for the channel", c do
    assert Hub.topic(c.youtube) =~
             ~r|^https://www\.youtube\.com/xml/feeds/videos\.xml\?channel_id=UC|
  end

  @callback_base "https://sikio.example.org/websub/"

  # The hub learns the topic, the callback and the secret. It answers 202 and verifies later.
  test "a request posts the subscription to Google's hub and stays pending", c do
    {:ok, sub} = Hub.ensure(c.youtube)
    parent = self()

    Req.Test.stub(Sikio.Feeds.HTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        parent,
        {:hub, conn.method, Plug.Conn.get_req_header(conn, "host"), URI.decode_query(body)}
      )

      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert {:ok, %{state: :pending, requested_at: %DateTime{}}} = Hub.request(sub, @callback_base)
    assert_received {:hub, "POST", ["pubsubhubbub.appspot.com"], form}

    assert form == %{
             "hub.mode" => "subscribe",
             "hub.topic" => Hub.topic(c.youtube),
             "hub.callback" => @callback_base <> sub.token,
             "hub.secret" => sub.secret,
             "hub.lease_seconds" => "864000"
           }

    Req.Test.stub(Sikio.Feeds.HTTP, &Plug.Conn.send_resp(&1, 500, ""))
    assert {:error, :unavailable} = Hub.request(sub, @callback_base)
  end

  # Once an hour: every followed YouTube feed gets a subscription. Pending ones are asked again
  # after a day, active ones at four fifths of their lease. Unfollowed feeds lose theirs.
  test "the sync requests what is due and drops what nobody follows", c do
    Req.Test.stub(Sikio.Feeds.HTTP, &Plug.Conn.send_resp(&1, 202, ""))
    now = ~U[2026-10-08 12:00:00.000000Z]

    assert [%{feed_id: feed_id}] = Hub.sync(now, @callback_base)
    assert feed_id == c.youtube.id
    assert [] = Hub.sync(DateTime.add(now, 23, :hour), @callback_base)
    assert [_] = Hub.sync(DateTime.add(now, 25, :hour), @callback_base)

    sub = Repo.get_by!(Hub.Subscription, feed_id: feed_id)

    Repo.update!(
      Ecto.Changeset.change(sub,
        state: :active,
        verified_at: now,
        lease_expires_at: DateTime.add(now, 10, :day),
        renew_at: DateTime.add(now, 8, :day)
      )
    )

    assert [] = Hub.sync(DateTime.add(now, 7, :day), @callback_base)
    assert [_] = Hub.sync(DateTime.add(now, 9, :day), @callback_base)

    # A lapsed lease counts as pending again, and polling resumes until the hub verifies.
    assert [%{state: :pending}] = Hub.sync(DateTime.add(now, 11, :day), @callback_base)

    Repo.update_all(Sikio.Library.Subscription, set: [paused: true])
    assert [] = Hub.sync(DateTime.add(now, 12, :day), @callback_base)
    assert Repo.aggregate(Hub.Subscription, :count) == 0
  end

  # A hub's denial is final, so the subscription is not asked for again.
  test "a denied subscription is not asked again", c do
    Req.Test.stub(Sikio.Feeds.HTTP, &Plug.Conn.send_resp(&1, 202, ""))
    now = ~U[2026-10-08 12:00:00.000000Z]
    {:ok, sub} = Hub.ensure(c.youtube)
    Repo.update!(Ecto.Changeset.change(sub, state: :denied, requested_at: now))

    assert [] = Hub.sync(DateTime.add(now, 30, :day), @callback_base)
  end

  test "a disabled hub syncs nothing", _c do
    assert [] = Hub.sync(DateTime.utc_now(), @callback_base, enabled: false)
    assert Repo.aggregate(Hub.Subscription, :count) == 0
  end

  # The hourly job subscribes with the instance's public URL as the callback base.
  test "the hourly job subscribes with the instance's callback URL", c do
    parent = self()

    Req.Test.stub(Sikio.Feeds.HTTP, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:callback, URI.decode_query(body)["hub.callback"]})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    assert :ok = perform_job(Sikio.Feeds.HubSync, %{})
    %{token: token} = Repo.get_by!(Hub.Subscription, feed_id: c.youtube.id)
    assert_received {:callback, callback}
    assert callback == SikioWeb.Endpoint.url() <> "/websub/" <> token
  end
end
