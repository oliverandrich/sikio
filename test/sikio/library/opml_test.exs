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

  # A folder names a tag. The innermost folder counts, and a feed listed in two folders is one
  # source with both tags.
  test "reads the folder a source stands in as its tag" do
    xml =
      document(
        ~s(<outline text="Tech"><outline text="A" xmlUrl="https://example.org/a"/>) <>
          ~s(<outline text="Inner"><outline text="B" xmlUrl="https://example.org/b"/></outline></outline>) <>
          ~s(<outline title="Must view"><outline text="A again" xmlUrl="https://example.org/a"/></outline>) <>
          ~s(<outline text="C" xmlUrl="https://example.org/c"/>)
      )

    assert {:ok, [a, b, c]} = OPML.parse(xml)
    assert {a.url, a.tags} == {"https://example.org/a", ["Tech", "Must view"]}
    assert b.tags == ["Inner"]
    assert c.tags == []
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
    alice = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    bob = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/feed?a=1&b=2")
    Library.subscribe(alice, %{preview | title: ~s(A & B "podcast")})
    Library.subscribe(bob, %{preview | url: "https://example.org/private"})
    xml = OPML.export(alice)

    assert {:ok, [%{title: ~s(A & B "podcast"), url: "https://example.org/feed?a=1&b=2"}]} =
             OPML.parse(xml)

    refute xml =~ "private"
    refute xml =~ "alice"
  end

  # Tags leave as folders, a subscription under each of its tags, and come back as tags.
  test "export writes a subscription under each of its tags" do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/tagged")
    {:ok, sub} = Library.subscribe(user, preview)
    {:ok, other} = Parser.parse(podcast("Plain"), "https://example.org/plain")
    {:ok, _} = Library.subscribe(user, other)
    {:ok, _} = Sikio.Tags.set(user, sub.id, ["Tech", "Must view"])

    assert {:ok, sources} = user |> OPML.export() |> OPML.parse()

    assert Enum.map(sources, &{&1.url, Enum.sort(&1.tags)}) |> Enum.sort() == [
             {"https://example.org/plain", []},
             {"https://example.org/tagged", ["Must view", "Tech"]}
           ]
  end

  # An imported source takes the tags its folders name; one already subscribed gains them.
  test "imports give their sources the tags the file names" do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/existing")
    {:ok, sub} = Library.subscribe(user, preview)
    {:ok, _} = Sikio.Tags.set(user, sub.id, ["Mine"])
    Req.Test.stub(HTTP, fn conn -> Plug.Conn.send_resp(conn, 200, podcast("New podcast")) end)

    OPML.import_sources(user, [
      %{title: "existing", url: "https://example.org/existing", tags: ["Tech"]},
      %{title: "new", url: "https://example.org/new", tags: ["Tech", "Later"]}
    ])

    tags = fn s -> user |> Sikio.Tags.of(s.id) |> Enum.map(& &1.name) end
    subscriptions = Map.new(Library.subscriptions(user), &{&1.feed.url, &1})
    assert tags.(subscriptions["https://example.org/existing"]) == ["Mine", "Tech"]
    assert tags.(subscriptions["https://example.org/new"]) == ["Later", "Tech"]
  end

  test "partial imports preserve existing paused subscriptions and progress and report failures" do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    {:ok, preview} = Parser.parse(podcast(), "https://example.org/existing")
    {:ok, sub} = Library.subscribe(user, preview)
    Library.pause(user, sub.id, true)
    [entry] = Library.entries(user)
    Playback.mark(user, entry.id, :heard)

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
    assert Library.entry(user, entry.id).playback.status == :heard
    assert [%{status: :existing}] = OPML.import_sources(user, [Enum.at(sources, 1)])
  end

  # Fifty sources one after another can take minutes. They are fetched a few at a time, so a slow
  # server delays its own source rather than every one behind it.
  test "sources are fetched at the same time and reported in the file's order" do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    test = self()

    Req.Test.stub(HTTP, fn conn ->
      held(test, fn -> Plug.Conn.send_resp(conn, 200, podcast(conn.request_path)) end)
    end)

    sources = for n <- 1..3, do: %{title: "#{n}", url: feed_url("source#{n}")}
    task = Task.async(fn -> OPML.import_sources(user, sources) end)

    result = release_together(task, 2)

    assert Enum.map(result, &{&1.title, &1.status}) == [
             {"1", :imported},
             {"2", :imported},
             {"3", :imported}
           ]

    assert user |> Library.subscriptions() |> Enum.map(& &1.feed.title) |> Enum.sort() ==
             ["/source1", "/source2", "/source3"]
  end

  test "private addresses never reach the HTTP transport" do
    user = Repo.insert!(User.changeset(%User{}, %{username: unique_username()}))
    Req.Test.stub(HTTP, fn _ -> flunk("private address reached transport") end)

    assert [%{status: :failed, reason: :unsafe_url}] =
             OPML.import_sources(user, [%{title: "Private", url: "http://127.0.0.1/rss"}])

    assert Library.subscriptions(user) == []
  end
end
