# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.SubscriptionsLiveTest do
  @moduledoc false
  use SikioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sikio.FeedFixtures

  alias Ithibati.Web.Gate
  alias Sikio.Accounts.User
  alias Sikio.Feeds.HTTP
  alias Sikio.Library
  alias Sikio.Repo

  setup %{conn: conn} do
    user = Repo.insert!(User.changeset(%User{}, %{username: "listener"}))
    conn = conn |> init_test_session(%{}) |> Gate.log_in(user)
    %{conn: conn, user: user}
  end

  test "pasted URLs preview a source before subscribing", %{conn: conn, user: user} do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    view |> form("#discover-form", %{url: "https://example.org/rss"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#source-0", "Small Hours")
    assert Library.subscriptions(user) == []
    view |> element("#source-0 button", "Subscribe") |> render_click()
    assert [%{feed: %{title: "Small Hours"}}] = Library.subscriptions(user)
    assert has_element?(view, "#subscriptions", "Small Hours")
  end

  test "Apple search results can be previewed and subscribed", %{conn: conn} do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/search" ->
          Req.Test.json(conn, %{
            results: [
              %{
                collectionName: "Small Hours",
                artistName: "Ada",
                feedUrl: "https://example.org/rss"
              }
            ]
          })

        "/rss" ->
          Plug.Conn.send_resp(conn, 200, podcast())
      end
    end)

    {:ok, view, _} = live(conn, ~p"/subscriptions")
    view |> form("#search-form", %{term: "small hours"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#source-0", "Ada")
    view |> element("#source-0 button", "Preview") |> render_click()
    render_async(view)
    assert has_element?(view, "#source-0 button", "Subscribe")
  end

  test "discovery failures are visible and forged result IDs do not subscribe", %{
    conn: conn,
    user: user
  } do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 503, "down") end)
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    view |> form("#discover-form", %{url: "https://example.org/rss"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "#discovery-error")
    render_hook(view, "select", %{id: "999"})
    assert Library.subscriptions(user) == []
  end

  # Both forms carry a phx-change handler, which is what lets a reconnecting browser put back what
  # somebody had typed. Without it the text is silently replaced by the template's empty value.
  test "what was typed survives a reconnect", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    view |> form("#discover-form", %{url: "https://example.org/rs"}) |> render_change()
    view |> form("#search-form", %{term: "small ho"}) |> render_change()

    html = render(view)
    assert html =~ "https://example.org/rs"
    assert html =~ "small ho"
  end

  test "pausing and unsubscribing act only on our own rows", %{conn: conn, user: user} do
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast()) end)
    {:ok, view, _} = live(conn, ~p"/subscriptions")
    view |> form("#discover-form", %{url: "https://example.org/rss"}) |> render_submit()
    render_async(view)
    view |> element("#source-0 button", "Subscribe") |> render_click()
    [subscription] = Library.subscriptions(user)

    view |> element("#subscription-#{subscription.id} button", "Pause") |> render_click()
    assert [%{paused: true}] = Library.subscriptions(user)

    view |> element("#subscription-#{subscription.id} button", "Resume") |> render_click()
    assert [%{paused: false}] = Library.subscriptions(user)

    view |> element("#subscription-#{subscription.id} button", "Unsubscribe") |> render_click()
    assert Library.subscriptions(user) == []
    assert has_element?(view, "#subscriptions-empty")
  end

  # The policy is written on a document, and moving inside a LiveView writes no document. A
  # PeerTube instance subscribed to without one would not be in the policy the page loaded with,
  # so its first video would be refused by the browser. Subscribing to a new instance therefore
  # asks for a page.
  test "subscribing to a new instance reloads the page that has to frame it", %{conn: conn} do
    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        path when path in [nil, "/"] ->
          Plug.Conn.send_resp(conn, 200, "<html><head></head><body></body></html>")

        "/.well-known/nodeinfo" ->
          Req.Test.json(conn, %{
            links: [
              %{
                rel: "http://nodeinfo.diaspora.software/ns/schema/2.0",
                href: "https://video.example.org/nodeinfo/2.0.json"
              }
            ]
          })

        "/nodeinfo/2.0.json" ->
          Req.Test.json(conn, %{software: %{name: "peertube"}})

        "/feeds/videos.xml" ->
          Plug.Conn.send_resp(conn, 200, peertube())
      end
    end)

    {:ok, view, _html} = live(conn, ~p"/subscriptions")

    view |> form("#discover-form", %{url: "https://video.example.org"}) |> render_submit()
    render_async(view)

    assert has_element?(view, "#source-0", "Good Instance Videos")

    assert {:error, {:redirect, %{to: "/subscriptions"}}} =
             view |> element("#source-0 button", "Subscribe") |> render_click()
  end
end
