# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.JobsTest do
  @moduledoc false
  use Sikio.DataCase, async: true
  use Oban.Testing, repo: Sikio.Repo

  import Ecto.Query
  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds.Feed
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Feeds.Refresh
  alias Sikio.Feeds.Scheduler
  alias Sikio.Library

  setup do
    url = feed_url()
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), url)
    {:ok, subscription} = Library.subscribe(user, preview)
    %{user: user, subscription: subscription, url: url}
  end

  test "schedules one refresh per active feed, whoever subscribed to it", ctx do
    # The same feed on purpose: one refresh is scheduled however many accounts want it.
    other = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), ctx.url)
    {:ok, _second} = Library.subscribe(other, preview)
    due_in(ctx.subscription.feed_id, minutes: -1)

    assert :ok = perform_job(Scheduler, %{})
    assert_enqueued(worker: Refresh, args: %{feed_id: ctx.subscription.feed_id})
    assert length(all_enqueued(worker: Refresh)) == 1
  end

  # Every request sets when the feed is asked next. The scheduler runs more often than any feed
  # is due, so the feeds spread over the hour.
  test "a feed is scheduled once its next check has come", ctx do
    id = ctx.subscription.feed_id

    due_in(id, minutes: 30)
    assert :ok = perform_job(Scheduler, %{})
    refute_enqueued(worker: Refresh)

    due_in(id, minutes: -1)
    assert :ok = perform_job(Scheduler, %{})
    assert_enqueued(worker: Refresh, args: %{feed_id: id})
  end

  # The moment is computed when the job runs, a little after the scheduler queued it. Without
  # leeway the feed would miss the run it was meant for and wait for the next one.
  test "a feed due within the next minute is scheduled now", ctx do
    due_in(ctx.subscription.feed_id, minutes: 0.5)

    assert :ok = perform_job(Scheduler, %{})
    assert_enqueued(worker: Refresh, args: %{feed_id: ctx.subscription.feed_id})
  end

  # A full queue can hold a refresh past the next run of the scheduler. It is still the one.
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

  # The schedule and the job disagree on purpose. A feed may be paused in the minutes between
  # being queued and being run, and the job is the one that asks last.
  test "a queued job does nothing after the last subscription is paused", ctx do
    {:ok, _paused} = Library.pause(ctx.user, ctx.subscription.id, true)
    due_in(ctx.subscription.feed_id, minutes: -1)

    assert :ok = perform_job(Scheduler, %{})
    refute_enqueued(worker: Refresh)
    assert :ok = perform_job(Refresh, %{feed_id: ctx.subscription.feed_id})
  end

  # The job is how new episodes arrive, so it is the one that sends them where subscriptions say.
  test "a refresh job sends new episodes where the subscription says", ctx do
    {:ok, _} = Library.update_subscription(ctx.user, ctx.subscription.id, %{delivery: :queue})

    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast_later()) end)
    assert :ok = perform_job(Refresh, %{feed_id: ctx.subscription.feed_id})
    assert [%{title: "Later"}] = Library.entries(ctx.user, %{"status" => "queue"})
  end

  test "a refresh job reports upstream failures for Oban retry", ctx do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "try later") end)

    assert {:error, :unavailable} = perform_job(Refresh, %{feed_id: ctx.subscription.feed_id})
  end

  test "the schedule runs the feed refresh" do
    options = Application.fetch_env!(:sikio, Oban)

    assert :ok = Oban.Config.validate(options)
    assert Enum.any?(options[:cron][:crontab], &match?({_expression, Scheduler}, &1))
  end

  defp due_in(feed_id, minutes: minutes) do
    at = DateTime.add(DateTime.utc_now(), round(minutes * 60), :second)
    Repo.update_all(from(f in Feed, where: f.id == ^feed_id), set: [next_check_at: at])
  end
end
