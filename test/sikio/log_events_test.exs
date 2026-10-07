# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.LogEventsTest do
  @moduledoc """
  The events production logs: what an operator acts on, by id, never by name, code or token.
  """
  use Sikio.DataCase, async: true
  use Oban.Testing, repo: Sikio.Repo

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint SikioWeb.Endpoint
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.Invitation
  alias Sikio.Accounts.User
  alias Sikio.Feeds
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias SikioWeb.Auth

  # A job that fails, as any of Sikio's may, with a reason as long as it likes.
  defmodule Failing do
    @moduledoc false
    use Oban.Worker
    @impl true
    def perform(%{args: %{"reason" => reason}}), do: {:error, reason}
  end

  # Hands this test the lines its processes log, at every level: its own, and those that name it
  # among their callers, as a LiveView under test does. A handler runs in the process that logs.
  defmodule Lines do
    @moduledoc false
    def log(event, %{config: %{to: to}}) do
      if to in [self() | Process.get(:"$callers", [])], do: send(to, {:line, event})
    end
  end

  setup do
    id = :"lines_#{System.unique_integer([:positive])}"
    :ok = :logger.add_handler(id, Lines, %{level: :all, config: %{to: self()}})
    on_exit(fn -> :logger.remove_handler(id) end)
  end

  @metadata [:account_id, :feed_id, :feed_title, :host, :reason, :worker, :job_id, :attempt]

  defp logged(fun) do
    fun.()
    collect([])
  end

  defp collect(lines) do
    receive do
      {:line, %{level: level, msg: msg, meta: meta}} ->
        message = with {:string, text} <- msg, do: IO.chardata_to_string(text)
        fields = for key <- @metadata, Map.has_key?(meta, key), do: "#{key}=#{meta[key]}"
        collect([Enum.join([level, message | fields], " ") | lines])
    after
      0 -> lines |> Enum.reverse() |> Enum.join("\n")
    end
  end

  defp key_attrs,
    do: %{key_id: :crypto.strong_rand_bytes(16), public_key: :crypto.strong_rand_bytes(64)}

  defp claim(username) do
    {:ok, _conn} = Auth.register(claiming_conn(), key_attrs(), username, %{})
    Repo.get_by!(User, username: username)
  end

  test "claiming the instance names the account by id" do
    log = logged(fn -> claim("first_claimant") end)
    account = Repo.get_by!(User, username: "first_claimant")

    assert log =~ "info instance claimed account_id=#{account.id}"
    refute log =~ "first_claimant"
  end

  test "an accepted invitation names the new account by id, and neither name nor token" do
    claim("first_claimant")

    invitation =
      %Invitation{} |> Invitation.changeset(%{"username" => "invited_one"}) |> Repo.insert!()

    log =
      logged(fn ->
        {:ok, _conn} =
          Auth.register(claiming_conn(), key_attrs(), "invited_one", %{
            "token" => invitation.token
          })
      end)

    account = Repo.get_by!(User, username: "invited_one")
    assert log =~ "info invitation accepted account_id=#{account.id}"
    refute log =~ "invited_one"
    refute log =~ invitation.token
  end

  test "signing in names the account by id" do
    account = claim("first_claimant")
    log = logged(fn -> {:ok, _conn} = Auth.authenticate(claiming_conn(), account) end)

    assert log =~ "info signed in account_id=#{account.id}"
    refute log =~ "first_claimant"
  end

  test "making an invitation names who made it, not whom it is for" do
    account = claim("first_claimant")

    conn =
      build_conn() |> Plug.Test.init_test_session(%{}) |> Gate.log_in(account)

    {:ok, view, _html} = live(conn, "/invitations")

    log =
      logged(fn ->
        view |> form("#invitation-form", %{"username" => "someone_else"}) |> render_submit()
      end)

    assert log =~ "info invitation made account_id=#{account.id}"
    refute log =~ "someone_else"
  end

  # The operator has to know which source fails: its title and host say so. A private feed may
  # carry its token in the path or the query, so the address itself stays out.
  test "a feed that cannot be fetched is a warning with its id, title, host and why" do
    {:ok, preview} = Parser.parse(podcast(), feed_url("private/a-feed-token.rss?auth=secret"))
    {:ok, feed} = Feeds.store(preview)
    Req.Test.stub(HTTP, &Plug.Conn.send_resp(&1, 410, ""))

    log = logged(fn -> Feeds.refresh(feed.id) end)
    host = URI.parse(feed.url).host

    assert log =~
             "warning feed refresh failed feed_id=#{feed.id} feed_title=#{feed.title} host=#{host} reason=gone"

    refute log =~ "a-feed-token"
    refute log =~ "secret"
  end

  # The feed's own line already says what failed and where; a second for its job says nothing more.
  test "a refresh that fails is one line, not one more for its job" do
    account = claim("first_claimant")
    {:ok, preview} = Parser.parse(podcast(), feed_url())
    {:ok, %{feed_id: feed_id}} = Sikio.Library.subscribe(account, preview)
    feed = Repo.get!(Sikio.Feeds.Feed, feed_id)
    Req.Test.stub(HTTP, &Plug.Conn.send_resp(&1, 410, ""))

    log = logged(fn -> perform_job(Sikio.Feeds.Refresh, %{feed_id: feed.id}) end)

    assert log =~ "feed refresh failed"
    refute log =~ "job failed"
  end

  test "a job that fails is a warning with its worker, id, attempt and a short reason" do
    log = logged(fn -> perform_job(Failing, %{reason: String.duplicate("x", 5000)}) end)

    assert log =~ "warning job failed"
    assert log =~ "worker=#{inspect(Failing)}"
    [reason] = Regex.run(~r/reason=(.*?)(?: worker=|$)/, log, capture: :all_but_first)
    assert String.length(reason) <= 200
  end
end
