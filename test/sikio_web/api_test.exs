# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.ApiTest do
  @moduledoc """
  The browser extension's API v1: a bearer token, the account's subscription identifiers, a
  lookup of the open page, subscribing to a source and adding an item.
  """
  use SikioWeb.ConnCase, async: true

  import Sikio.ExtensionFixtures
  import Sikio.FeedFixtures

  alias Sikio.Accounts.User
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Repo

  # A show at its own host: an episode page that names its feed, and the feed linking back.
  setup do
    ada = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    host = "https://show#{Sikio.DataCase.unique()}.example.org"
    page = host <> "/episodes/1"
    feed = host <> "/feed.xml"
    body = String.replace(podcast(), podcast_page(), page)

    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/episodes/1" ->
          html = ~s(<link rel="alternate" type="application/rss+xml" href="/feed.xml">)
          Plug.Conn.send_resp(conn, 200, html)

        "/feed.xml" ->
          Plug.Conn.send_resp(conn, 200, body)

        _ ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end)

    %{ada: ada, token: token(ada), page: page, feed: feed}
  end

  defp api(token), do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  test "a request without a valid token is refused", c do
    conn = get(build_conn(), "/api/v1/subscriptions")
    assert json_response(conn, 401) == %{"error" => "invalid_token"}
    assert get_resp_header(conn, "www-authenticate") == ["Bearer"]

    assert c.token
           |> String.reverse()
           |> api()
           |> get("/api/v1/subscriptions")
           |> json_response(401)
  end

  # The extension matches these against the open page itself, so Sikio learns no visited page.
  test "the subscriptions name each source's identifiers", c do
    {:ok, preview} = Parser.parse(youtube(), youtube_feed_url())
    {:ok, _} = Library.subscribe(c.ada, preview)

    assert %{"subscriptions" => [source]} =
             c.token |> api() |> get("/api/v1/subscriptions") |> json_response(200)

    assert %{"kind" => "youtube", "feed_url" => feed_url, "channel_id" => "UC" <> _} = source
    assert feed_url == preview.url
  end

  test "a lookup names the page's source and item and what the account has", c do
    lookup = fn ->
      c.token |> api() |> post("/api/v1/lookup", %{"url" => c.page}) |> json_response(200)
    end

    assert %{
             "sources" => [%{"feed_url" => feed, "title" => "Small Hours", "subscribed" => false}],
             "item" => %{"title" => "One & two", "source" => "Small Hours", "place" => nil}
           } = lookup.()

    assert feed == c.feed

    assert c.token
           |> api()
           |> post("/api/v1/items", %{"url" => c.page, "at" => "queue"})
           |> json_response(201) == %{"item" => %{"title" => "One & two", "place" => "queue"}}

    assert c.token
           |> api()
           |> post("/api/v1/subscriptions", %{"feed_url" => c.feed})
           |> json_response(201)
           |> get_in(["subscription", "feed_url"]) == c.feed

    assert %{"sources" => [%{"subscribed" => true}], "item" => %{"place" => "queue"}} = lookup.()
  end

  # RFC 6750 names the scheme case-insensitively.
  test "the scheme may be written in any case", c do
    conn = build_conn() |> put_req_header("authorization", "bearer " <> c.token)
    assert conn |> get("/api/v1/subscriptions") |> json_response(200)
  end

  # Subscribing to the feed the extension chose, never another one the page offers.
  test "a feed URL the page does not offer subscribes to nothing", c do
    assert c.token
           |> api()
           |> post("/api/v1/subscriptions", %{"feed_url" => c.page})
           |> json_response(404) == %{"error" => "not_found"}

    assert c.token |> api() |> get("/api/v1/subscriptions") |> json_response(200) ==
             %{"subscriptions" => []}
  end

  test "subscribing again answers 200 and keeps the subscription", c do
    subscribe = fn ->
      c.token |> api() |> post("/api/v1/subscriptions", %{"feed_url" => c.feed})
    end

    assert subscribe.() |> json_response(201)
    assert subscribe.() |> json_response(200) |> get_in(["subscription", "feed_url"]) == c.feed
  end

  test "a page with nothing to add has no source and no item", c do
    assert c.token
           |> api()
           |> post("/api/v1/lookup", %{"url" => c.feed <> "/missing"})
           |> json_response(200) == %{"sources" => [], "item" => nil}
  end

  test "a request missing its fields or naming another place is refused", c do
    assert c.token
           |> api()
           |> post("/api/v1/items", %{"url" => c.page, "at" => "elsewhere"})
           |> json_response(400) == %{"error" => "invalid_request"}

    assert c.token |> api() |> post("/api/v1/lookup", %{}) |> json_response(400) ==
             %{"error" => "invalid_request"}

    assert c.token
           |> api()
           |> post("/api/v1/items", %{"url" => c.feed <> "/missing", "at" => "inbox"})
           |> json_response(404) == %{"error" => "not_found"}
  end

  # A platform an administrator switched off takes no new subscriptions or items.
  test "a platform that is off takes nothing new", c do
    admin = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    admin = Repo.update!(Ecto.Changeset.change(admin, admin: true))
    {:ok, _} = Sikio.Platforms.set(admin, :podcast, false)

    assert c.token
           |> api()
           |> post("/api/v1/items", %{"url" => c.page, "at" => "inbox"})
           |> json_response(403) == %{"error" => "platform_off"}

    assert c.token
           |> api()
           |> post("/api/v1/subscriptions", %{"feed_url" => c.feed})
           |> json_response(403) == %{"error" => "platform_off"}
  end
end

defmodule SikioWeb.ApiRateLimitTest do
  @moduledoc """
  The browser extension's requests count against the account's `api` budget.
  """
  # Not async: the test sets the budget in application configuration.
  use SikioWeb.ConnCase, async: false

  import Sikio.ExtensionFixtures

  alias Sikio.Accounts.User
  alias Sikio.Repo
  alias Sikio.TestConfig

  test "requests beyond the budget are refused with a wait" do
    TestConfig.put_budget(:api, {1, 60})
    ada = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    token = token(ada)
    api = fn -> build_conn() |> put_req_header("authorization", "Bearer " <> token) end

    assert api.() |> get("/api/v1/subscriptions") |> json_response(200)

    conn = api.() |> get("/api/v1/subscriptions")
    assert json_response(conn, 429) == %{"error" => "rate_limited"}
    assert [_seconds] = get_resp_header(conn, "retry-after")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  # Guessing tokens costs a lookup each, so failed requests count per client address.
  test "requests with unknown tokens are limited per address" do
    TestConfig.put_budget(:api, {1, 60})
    guess = fn -> build_conn() |> put_req_header("authorization", "Bearer nope") end

    assert guess.() |> get("/api/v1/subscriptions") |> json_response(401)
    assert guess.() |> get("/api/v1/subscriptions") |> json_response(429)
  end
end
