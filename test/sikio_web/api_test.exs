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

  describe "POST /api/v1/subscriptions/match" do
    defp match(token, feed_urls, channel_ids \\ []) do
      body = %{"feed_urls" => feed_urls, "channel_ids" => channel_ids}
      token |> api() |> post("/api/v1/subscriptions/match", body)
    end

    defp subscribe_feed(c),
      do: c.token |> api() |> post("/api/v1/subscriptions", %{"feed_url" => c.feed})

    # The extension sends the sources it detected on a page, never the page itself.
    test "names the sent feed URLs and channel ids the account subscribes to", c do
      assert subscribe_feed(c) |> json_response(201)
      channel_feed = youtube_feed_url()
      {:ok, preview} = Parser.parse(youtube(), channel_feed)
      {:ok, _} = Library.subscribe(c.ada, preview)
      channel = URI.decode_query(URI.parse(channel_feed).query)["channel_id"]
      other = String.replace(c.feed, "/feed.xml", "/other.xml")

      assert c.token |> match([c.feed, other], [channel, "UCunknown"]) |> json_response(200) ==
               %{"feed_urls" => [c.feed], "channel_ids" => [channel]}
    end

    # A page may write the feed's URL with http, a trailing slash, another case in the host, the
    # default port, an empty query or a fragment.
    test "a feed URL matches in another spelling, as written", c do
      assert subscribe_feed(c) |> json_response(201)

      spellings = [
        String.replace(c.feed, "https://", "http://"),
        c.feed <> "/",
        String.replace(c.feed, "https://show", "https://SHOW"),
        String.replace(c.feed, ".example.org/", ".example.org:443/"),
        c.feed <> "?",
        c.feed <> "#latest"
      ]

      assert c.token |> match(spellings) |> json_response(200) ==
               %{"feed_urls" => spellings, "channel_ids" => []}
    end

    test "a feed URL matches through an alias of a subscribed feed", c do
      canonical = feed_url("feed/mp3/")
      alias_url = String.replace(canonical, "/feed/", "/index.php/feed/")
      named = podcast_naming(canonical)
      Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, named) end)

      assert c.token
             |> api()
             |> post("/api/v1/subscriptions", %{"feed_url" => alias_url})
             |> json_response(201)

      assert c.token |> match([alias_url]) |> json_response(200) ==
               %{"feed_urls" => [alias_url], "channel_ids" => []}
    end

    test "another account's subscriptions do not count", c do
      assert subscribe_feed(c) |> json_response(201)
      bea = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))

      assert bea |> token() |> match([c.feed]) |> json_response(200) ==
               %{"feed_urls" => [], "channel_ids" => []}
    end

    test "missing, malformed or oversized lists are refused", c do
      refused = %{"error" => "invalid_request"}
      post_match = &(c.token |> api() |> post("/api/v1/subscriptions/match", &1))

      assert post_match.(%{}) |> json_response(400) == refused
      assert post_match.(%{"feed_urls" => [c.feed]}) |> json_response(400) == refused

      assert post_match.(%{"feed_urls" => c.feed, "channel_ids" => []}) |> json_response(400) ==
               refused

      assert post_match.(%{"feed_urls" => [1], "channel_ids" => []}) |> json_response(400) ==
               refused

      too_many = for n <- 1..51, do: "#{c.feed}?n=#{n}"
      assert c.token |> match(too_many) |> json_response(400) == refused
      assert c.token |> match(Enum.take(too_many, 50)) |> json_response(200)
    end
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

  # A page may link a feed at a URL other than the one its `atom:link rel="self"` gives. Sikio
  # stores the feed at the self URL. The extension matches and subscribes with the linked URL.
  test "a feed fetched at another URL than its self URL is known by both", c do
    canonical = feed_url("feed/mp3/")
    alias_url = String.replace(canonical, "/feed/", "/index.php/feed/")
    named = podcast_naming(canonical)

    Req.Test.stub(HTTP, fn conn ->
      if conn.request_path in ["/feed/mp3/", "/index.php/feed/mp3/"],
        do: Plug.Conn.send_resp(conn, 200, named),
        else: Plug.Conn.send_resp(conn, 404, "")
    end)

    subscribe = fn ->
      c.token |> api() |> post("/api/v1/subscriptions", %{"feed_url" => alias_url})
    end

    assert subscribe.() |> json_response(201) |> get_in(["subscription", "feed_url"]) == canonical

    assert subscribe.() |> json_response(200) |> get_in(["subscription", "aliases"]) == [
             alias_url
           ]

    assert %{"subscriptions" => [%{"feed_url" => ^canonical, "aliases" => [^alias_url]}]} =
             c.token |> api() |> get("/api/v1/subscriptions") |> json_response(200)
  end

  # The account followed the feed at its self URL before Sikio knew the other URL.
  test "subscribing through another URL of a followed feed answers 200", c do
    canonical = feed_url("feed/mp3/")
    alias_url = String.replace(canonical, "/feed/", "/index.php/feed/")
    named = podcast_naming(canonical)
    {:ok, stored} = Parser.parse(named, canonical)
    {:ok, _} = Library.subscribe(c.ada, stored)
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, named) end)

    assert c.token
           |> api()
           |> post("/api/v1/subscriptions", %{"feed_url" => alias_url})
           |> json_response(200)
           |> get_in(["subscription", "feed_url"]) == canonical
  end

  # The extension sends the URL as the page writes it. It may redirect to the feed, or differ
  # from the stored URL in the host's case.
  test "a feed URL that redirects or is spelled differently subscribes to the feed", c do
    old = String.replace(c.feed, "/feed.xml", "/old.xml")
    body = String.replace(podcast(), podcast_page(), c.page)

    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/old.xml" ->
          conn |> Plug.Conn.put_resp_header("location", c.feed) |> Plug.Conn.send_resp(301, "")

        "/feed.xml" ->
          Plug.Conn.send_resp(conn, 200, body)
      end
    end)

    subscribe = fn url ->
      c.token |> api() |> post("/api/v1/subscriptions", %{"feed_url" => url})
    end

    assert old |> subscribe.() |> json_response(201) |> get_in(["subscription", "feed_url"]) ==
             c.feed

    assert String.replace(c.feed, "https://show", "HTTPS://SHOW")
           |> subscribe.()
           |> json_response(200)
           |> get_in(["subscription", "aliases"]) == [old]
  end

  # An exit inside the fetch, such as a pool timeout, must not fail the request.
  test "a lookup survives an exit while the page is fetched", c do
    Req.Test.stub(HTTP, fn _conn -> exit(:pool_timeout) end)

    assert c.token
           |> api()
           |> post("/api/v1/lookup", %{"url" => c.page})
           |> json_response(200) == %{"sources" => [], "item" => nil}
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
  # They count in a group of their own, so they cannot crowd out the accounts' counters.
  test "requests with unknown tokens are limited per address" do
    TestConfig.put_budget(:api_address, {1, 60})
    guess = fn -> build_conn() |> put_req_header("authorization", "Bearer nope") end

    assert guess.() |> get("/api/v1/subscriptions") |> json_response(401)
    assert guess.() |> get("/api/v1/subscriptions") |> json_response(429)
  end

  test "token exchanges are limited per address" do
    TestConfig.put_budget(:api_address, {1, 60})
    exchange = fn -> build_conn() |> post("/api/v1/token", %{"code" => "x"}) end

    assert exchange.() |> json_response(400)
    assert exchange.() |> json_response(429)
  end
end
