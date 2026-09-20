# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.OPMLTest do
  @moduledoc false
  use Sikio.DataCase, async: true
  import Sikio.FeedFixtures
  alias Sikio.Accounts.User
  alias Sikio.Feeds.HTTP
  alias Sikio.Feeds.Parser
  alias Sikio.Library
  alias Sikio.Library.OPML
  alias Sikio.Playback

  defp document(body),
    do: ~s(<opml version="2.0"><head><title>Sources</title></head><body>#{body}</body></opml>)

  test "reads folders, decodes XML attributes and deduplicates normalized feed URLs" do
    xml =
      document(
        ~s(<outline text="Folder"><outline text="A &amp; B" xmlUrl="https://EXAMPLE.org/feed?a=1&amp;b=2"/><outline text="Duplicate" xmlUrl="https://example.org/feed?a=1&amp;b=2"/></outline>)
      )

    assert {:ok, [%{title: "A & B", url: "https://example.org/feed?a=1&b=2"}]} = OPML.parse(xml)
  end

  test "rejects malformed XML, DTDs, oversized files, excessive nesting and too many feeds" do
    assert {:error, :invalid_opml} = OPML.parse("<rss/>")

    assert {:error, :invalid_opml} =
             OPML.parse(
               "<!DOCTYPE opml [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><opml><body>&x;</body></opml>"
             )

    assert {:error, :too_large} = OPML.parse(String.duplicate("a", 1_000_001))
    nested = String.duplicate("<outline>", 40) <> String.duplicate("</outline>", 40)
    assert {:error, :invalid_opml} = OPML.parse(document(nested))
    many = Enum.map_join(1..51, fn n -> ~s(<outline xmlUrl="https://example.org/#{n}"/>) end)
    assert {:error, :too_many_sources} = OPML.parse(document(many))
    assert {:error, :no_sources} = OPML.parse(document("<outline text='Empty folder'/>"))
  end

  test "export contains only this account's feeds and round trips escaped titles and URLs" do
    alice = Repo.insert!(User.changeset(%User{}, %{username: "alice"}))
    bob = Repo.insert!(User.changeset(%User{}, %{username: "bob"}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/feed?a=1&b=2")
    Library.subscribe(alice, %{preview | title: ~s(A & B "podcast")})
    Library.subscribe(bob, %{preview | url: "https://example.org/private"})
    xml = OPML.export(alice)

    assert {:ok, [%{title: ~s(A & B "podcast"), url: "https://example.org/feed?a=1&b=2"}]} =
             OPML.parse(xml)

    refute xml =~ "private"
    refute xml =~ "alice"
  end

  test "partial imports preserve existing paused subscriptions and progress and report failures" do
    user = Repo.insert!(User.changeset(%User{}, %{username: "listener"}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/existing")
    {:ok, sub} = Library.subscribe(user, preview)
    Library.pause(user, sub.id, true)
    [entry] = Library.entries(user)
    Playback.mark(user, entry.id, :completed)

    Req.Test.stub(HTTP, fn conn ->
      case conn.request_path do
        "/new" -> Plug.Conn.send_resp(conn, 200, podcast("New podcast"))
        "/broken" -> Plug.Conn.send_resp(conn, 503, "down")
        other -> flunk("unexpected request: #{other}")
      end
    end)

    sources =
      for path <- ["existing", "new", "broken"],
          do: %{title: path, url: "https://example.org/#{path}"}

    result = OPML.import_sources(user, sources)
    assert Enum.map(result, & &1.status) == [:existing, :imported, :failed]
    assert length(Library.subscriptions(user)) == 2
    assert Enum.find(Library.subscriptions(user), &(&1.id == sub.id)).paused
    assert Library.entry(user, entry.id).playback.status == :completed
    assert [%{status: :existing}] = OPML.import_sources(user, [Enum.at(sources, 1)])
  end

  test "private addresses never reach the HTTP transport" do
    user = Repo.insert!(User.changeset(%User{}, %{username: "listener"}))
    Req.Test.stub(HTTP, fn _ -> flunk("private address reached transport") end)

    assert [%{status: :failed, reason: :unsafe_url}] =
             OPML.import_sources(user, [%{title: "Private", url: "http://127.0.0.1/rss"}])

    assert Library.subscriptions(user) == []
  end
end
