# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.JobsTest do
  @moduledoc false
  use Sikio.DataCase, async: true
  use Oban.Testing, repo: Sikio.Repo

  import Ecto.Query
  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.Artwork
  alias Sikio.Feeds.Entry
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Feeds.Refresh
  alias Sikio.Feeds.Scheduler
  alias Sikio.Library
  alias Sikio.Library.Events

  setup do
    url = feed_url()
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), url)
    {:ok, subscription} = Library.subscribe(user, preview)
    %{user: user, subscription: subscription, url: url}
  end

  # The logo appears seconds after subscribing, not at the feed's next poll.
  test "subscribing to a podcast without artwork asks Apple's directory for it", ctx do
    assert ctx.subscription.feed.icon_url, "the fixture carries its own artwork"
    refute_enqueued(worker: Artwork)

    url = feed_url()
    {:ok, preview} = Parser.parse(podcast("Bare"), url)
    {:ok, %{feed_id: id}} = Library.subscribe(ctx.user, %{preview | icon_url: nil})
    assert_enqueued(worker: Artwork, args: %{feed_id: id})

    Req.Test.stub(HTTP, fn conn ->
      Req.Test.json(conn, %{
        results: [%{feedUrl: url, artworkUrl600: "https://img.example/a.jpg"}]
      })
    end)

    Events.subscribe_updates(ctx.user)
    assert :ok = perform_job(Artwork, %{feed_id: id})
    assert Repo.get(Feed, id).icon_url == "https://img.example/a.jpg"
    assert_received :library_changed, "sidebar and list show the new artwork"
  end

  # A picture a programme stored earlier stays through a refresh, which names none.
  test "a refresh keeps a Mediathek programme's stored picture", ctx do
    url = "https://mediathekviewweb.de/feed?query=%21ard+%23Maus&size=20"
    {:ok, preview} = Parser.parse(mediathek_feed(), url)
    {:ok, %{feed_id: feed_id}} = Library.subscribe(ctx.user, preview)
    [entry] = Repo.all(from e in Entry, where: e.feed_id == ^feed_id)

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [image_url: "https://img/1.jpg"]
    )

    Req.Test.stub(HTTP, &Plug.Conn.send_resp(&1, 200, mediathek_feed()))
    assert {:ok, _} = Feeds.refresh(feed_id)
    assert Repo.get(Entry, entry.id).image_url == "https://img/1.jpg"
  end

  test "schedules one refresh per active feed, whoever subscribed to it", ctx do
    # Two accounts subscribe to the same feed. The scheduler enqueues one refresh.
    other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), ctx.url)
    {:ok, _second} = Library.subscribe(other, preview)
    due_in(ctx.subscription.feed_id, minutes: -1)

    assert :ok = perform_job(Scheduler, %{})
    assert_enqueued(worker: Refresh, args: %{feed_id: ctx.subscription.feed_id})
    assert length(all_enqueued(worker: Refresh)) == 1
  end

  # Each refresh sets `next_check_at`. The scheduler runs more often than any feed is due and
  # enqueues only due feeds.
  test "a feed is scheduled once its next check has come", ctx do
    id = ctx.subscription.feed_id

    due_in(id, minutes: 30)
    assert :ok = perform_job(Scheduler, %{})
    refute_enqueued(worker: Refresh)

    due_in(id, minutes: -1)
    assert :ok = perform_job(Scheduler, %{})
    assert_enqueued(worker: Refresh, args: %{feed_id: id})
  end

  # The scheduler compares due times when it runs, slightly after cron enqueued it.
  # Without a one-minute leeway, a feed would miss this run and wait for the next.
  test "a feed due within the next minute is scheduled now", ctx do
    due_in(ctx.subscription.feed_id, minutes: 0.5)

    assert :ok = perform_job(Scheduler, %{})
    assert_enqueued(worker: Refresh, args: %{feed_id: ctx.subscription.feed_id})
  end

  # A busy queue can delay a refresh past the next scheduler run. No duplicate is enqueued.
  test "a refresh still waiting in the queue is not queued twice", ctx do
    due_in(ctx.subscription.feed_id, minutes: -1)
    assert :ok = perform_job(Scheduler, %{})
    Repo.update_all(Oban.Job, set: [inserted_at: DateTime.add(DateTime.utc_now(), -6, :minute)])

    assert :ok = perform_job(Scheduler, %{})
    assert length(all_enqueued(worker: Refresh)) == 1
  end

  test "a feed without a next check is due at once", ctx do
    Repo.update_all(from(f in Feed, where: f.id == ^ctx.subscription.feed_id),
      set: [next_check_at: nil]
    )

    assert :ok = perform_job(Scheduler, %{})
    assert_enqueued(worker: Refresh, args: %{feed_id: ctx.subscription.feed_id})
  end

  # A feed may be paused between enqueue and execution, so `Refresh` rechecks subscriptions.
  # No HTTP stub is registered, so a request would raise.
  test "a queued job does nothing after the last subscription is paused", ctx do
    {:ok, _paused} = Library.pause(ctx.user, ctx.subscription.id, true)
    due_in(ctx.subscription.feed_id, minutes: -1)

    assert :ok = perform_job(Scheduler, %{})
    refute_enqueued(worker: Refresh)
    assert :ok = perform_job(Refresh, %{feed_id: ctx.subscription.feed_id})
  end

  # `Refresh` delivers new entries according to the subscription's `delivery` setting.
  test "a refresh job sends new episodes where the subscription says", ctx do
    {:ok, _} = Library.configure(ctx.user, ctx.subscription.id, %{delivery: :queue}, [])

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast_later()) end)
    assert :ok = perform_job(Refresh, %{feed_id: ctx.subscription.feed_id})
    assert [%{title: "Later"}] = Library.entries(ctx.user, %{"status" => "queue"})
  end

  # A 429 with `Retry-After` returns `:ok`, so Oban does not retry. `next_check_at` carries the
  # wait.
  test "a refresh job returns :ok when the server asked to wait", ctx do
    Req.Test.stub(HTTP, fn conn ->
      conn |> Plug.Conn.put_resp_header("retry-after", "3600") |> Plug.Conn.send_resp(429, "")
    end)

    assert :ok = perform_job(Refresh, %{feed_id: ctx.subscription.feed_id})
  end

  test "a refresh job reports upstream failures for Oban retry", ctx do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "try later") end)

    assert {:error, :unavailable} = perform_job(Refresh, %{feed_id: ctx.subscription.feed_id})
  end

  describe "a member's refresh" do
    test "queues the subscribed feed", ctx do
      checked_ago(ctx.subscription.feed_id, minutes: 2)

      assert Library.refresh(ctx.user, ctx.subscription.id) == {:ok, ctx.subscription.feed_id}
      assert_enqueued(worker: Refresh, args: %{feed_id: ctx.subscription.feed_id})
    end

    # Feeds are shared, so a click series would reach another server once per click.
    test "skips a feed checked within the last minute", ctx do
      checked_ago(ctx.subscription.feed_id, minutes: 0.5)

      assert {:error, :recent} = Library.refresh(ctx.user, ctx.subscription.id)
      refute_enqueued(worker: Refresh)
    end

    # A Retry-After stored in `next_check_at` does not hold back a manual refresh.
    test "ignores the feed's next check", ctx do
      checked_ago(ctx.subscription.feed_id, minutes: 2)
      due_in(ctx.subscription.feed_id, minutes: 60)

      assert Library.refresh(ctx.user, ctx.subscription.id) == {:ok, ctx.subscription.feed_id}
      assert_enqueued(worker: Refresh, args: %{feed_id: ctx.subscription.feed_id})
    end

    # A failed scheduled refresh can wait in `retryable` for its backoff. The click starts it now.
    test "pulls a waiting retry forward", ctx do
      checked_ago(ctx.subscription.feed_id, minutes: 2)
      later = DateTime.add(DateTime.utc_now(), 1, :hour)

      %{feed_id: ctx.subscription.feed_id}
      |> Refresh.new(scheduled_at: later)
      |> Oban.insert!()

      Repo.update_all(Oban.Job, set: [state: "retryable"])

      assert {:ok, _} = Library.refresh(ctx.user, ctx.subscription.id)
      assert [job] = Repo.all(Oban.Job)
      assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) != :gt
    end

    test "rejects another account's or a paused subscription", ctx do
      checked_ago(ctx.subscription.feed_id, minutes: 2)
      other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
      assert {:error, :not_found} = Library.refresh(other, ctx.subscription.id)

      {:ok, _paused} = Library.pause(ctx.user, ctx.subscription.id, true)
      assert {:error, :not_found} = Library.refresh(ctx.user, ctx.subscription.id)
      refute_enqueued(worker: Refresh)
    end

    test "queues all active feeds not checked within the last minute", ctx do
      {:ok, %{feed_id: recent}} = subscribe(ctx.user)
      {:ok, paused} = subscribe(ctx.user)
      {:ok, _paused} = Library.pause(ctx.user, paused.id, true)
      checked_ago(paused.feed_id, minutes: 2)
      checked_ago(ctx.subscription.feed_id, minutes: 2)

      # Another account's feed stays out.
      other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
      {:ok, foreign} = subscribe(other)
      checked_ago(foreign.feed_id, minutes: 2)

      assert Library.refresh_all(ctx.user) == [ctx.subscription.feed_id]
      assert [%{args: %{"feed_id" => id}}] = all_enqueued(worker: Refresh)
      assert id == ctx.subscription.feed_id
      refute id == recent
    end
  end

  # A 304 or a repeated failure sends no `:library_changed`, yet the page waits for a result.
  # Only a page waiting for this feed follows the topic, so a scheduled poll queries nothing more.
  test "every refresh attempt reports on the feed's topic", ctx do
    id = ctx.subscription.feed_id
    Refresh.subscribe(id)

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 304, "") end)
    assert :ok = perform_job(Refresh, %{feed_id: id})
    assert_received {:feed_checked, ^id}

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "try later") end)
    assert {:error, :unavailable} = perform_job(Refresh, %{feed_id: id})
    assert_received {:feed_checked, ^id}

    {:ok, _paused} = Library.pause(ctx.user, ctx.subscription.id, true)
    assert :ok = perform_job(Refresh, %{feed_id: id})
    assert_received {:feed_checked, ^id}
  end

  # Without the report, the page would show the refresh as running until a reload.
  test "a refresh that raises still reports", ctx do
    id = ctx.subscription.feed_id
    Refresh.subscribe(id)
    Req.Test.stub(HTTP, fn _conn -> raise "boom" end)

    assert_raise RuntimeError, fn -> perform_job(Refresh, %{feed_id: id}) end
    assert_received {:feed_checked, ^id}
  end

  test "the schedule runs the feed refresh" do
    options = Sikio.Application.oban()

    assert :ok = Oban.Config.validate(options)
    assert Enum.any?(options[:cron][:crontab], &match?({_expression, Scheduler}, &1))
  end

  defp subscribe(user) do
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    Library.subscribe(user, preview)
  end

  defp checked_ago(feed_id, minutes: minutes) do
    at = DateTime.add(DateTime.utc_now(), -round(minutes * 60), :second)
    Repo.update_all(from(f in Feed, where: f.id == ^feed_id), set: [last_checked_at: at])
  end

  defp due_in(feed_id, minutes: minutes) do
    at = DateTime.add(DateTime.utc_now(), round(minutes * 60), :second)
    Repo.update_all(from(f in Feed, where: f.id == ^feed_id), set: [next_check_at: at])
  end
end
