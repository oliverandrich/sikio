defmodule Sikio.Feeds.JobsTest do
  @moduledoc false
  use Sikio.DataCase, async: true
  use Oban.Testing, repo: Sikio.Repo

  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Feeds.Refresh
  alias Sikio.Feeds.Scheduler
  alias Sikio.Library

  setup do
    user = Repo.insert!(User.changeset(%User{}, %{username: "alice"}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, subscription} = Library.subscribe(user, preview)
    %{user: user, subscription: subscription}
  end

  test "schedules one refresh per active feed, whoever subscribed to it", ctx do
    other = Repo.insert!(User.changeset(%User{}, %{username: "bob"}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/rss")
    {:ok, _second} = Library.subscribe(other, preview)

    assert :ok = perform_job(Scheduler, %{})
    assert_enqueued(worker: Refresh, args: %{feed_id: ctx.subscription.feed_id})
    assert length(all_enqueued(worker: Refresh)) == 1
  end

  # The schedule and the job disagree on purpose. A feed may be paused in the minutes between
  # being queued and being run, and the job is the one that asks last.
  test "a queued job does nothing after the last subscription is paused", ctx do
    {:ok, _paused} = Library.pause(ctx.user, ctx.subscription.id, true)

    assert :ok = perform_job(Scheduler, %{})
    refute_enqueued(worker: Refresh)
    assert :ok = perform_job(Refresh, %{feed_id: ctx.subscription.feed_id})
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
end
