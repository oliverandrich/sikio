# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryPathsTest do
  @moduledoc """
  Conversion between library filters and URL paths, in both directions.

  The library filters by status, source, tag and search. `LibraryPaths` encodes them as paths and
  reads paths back into filters and an item id.
  """
  use ExUnit.Case, async: true

  alias SikioWeb.LibraryPaths

  @none %{"status" => "", "source" => "", "tag" => "", "q" => "", "day" => "", "offset" => 0}
  @feeds %{106 => "MeTacheles Tonspur"}
  @item %{id: 4056, title: "KI-Verfassung - Die irre Selbstkontrolle der Tech-Bros"}

  defp filters(changes), do: Map.merge(@none, changes)

  # The time zone offset comes from the browser, not from the address.
  test "the history's day stays in the query string" do
    day = filters(%{"status" => "heard", "day" => "2026-10-07", "offset" => 120})
    assert LibraryPaths.library_path(day) == "/history?day=2026-10-07"
    assert LibraryPaths.library_path(%{day | "q" => "akku"}) == "/history?day=2026-10-07&q=akku"

    assert LibraryPaths.read_path("/history", %{"day" => "2026-10-07", "offset" => "120"}) ==
             {%{day | "offset" => 0}, nil}

    assert LibraryPaths.read_path("/inbox", %{"day" => "2026-10-07"}) ==
             {filters(%{"status" => "inbox"}), nil}
  end

  test "a list by status is its own path, and no filter is /all" do
    assert LibraryPaths.library_path(filters(%{"status" => "inbox"})) == "/inbox"
    assert LibraryPaths.library_path(filters(%{"status" => "queue"})) == "/queue"
    assert LibraryPaths.library_path(filters(%{"status" => "heard"})) == "/history"
    assert LibraryPaths.library_path(@none) == "/all"
  end

  # A source path without a status segment opens the source's inbox.
  test "a source is named by its number and its title, and opens on its inbox" do
    assert LibraryPaths.library_path(
             filters(%{"source" => "106", "status" => "inbox"}),
             nil,
             @feeds
           ) ==
             "/feeds/106-metacheles-tonspur"

    assert LibraryPaths.library_path(filters(%{"source" => "106"}), nil, @feeds) ==
             "/feeds/106-metacheles-tonspur/all"

    assert LibraryPaths.library_path(
             filters(%{"source" => "106", "status" => "heard"}),
             nil,
             @feeds
           ) ==
             "/feeds/106-metacheles-tonspur/history"

    assert LibraryPaths.library_path(filters(%{"source" => "7", "status" => "inbox"})) ==
             "/feeds/7",
           "a source without a known title keeps its number alone"

    assert LibraryPaths.place_path("source", "106", @feeds) == "/feeds/106-metacheles-tonspur"
  end

  # Tag paths follow the source scheme: id and slug, with the inbox as default status.
  test "a tag is named by its number and its name, and opens on its inbox" do
    tags = %{{:tag, 3} => "Must view"}

    assert LibraryPaths.library_path(filters(%{"tag" => "3", "status" => "inbox"}), nil, tags) ==
             "/tags/3-must-view"

    assert LibraryPaths.library_path(filters(%{"tag" => "3"}), nil, tags) ==
             "/tags/3-must-view/all"

    assert LibraryPaths.library_path(filters(%{"tag" => "3", "status" => "inbox"}), @item, tags) ==
             "/tags/3-must-view/4056-ki-verfassung-die-irre-selbstkontrolle-der-tech-bros"

    assert LibraryPaths.place_path("tag", "3", tags) == "/tags/3-must-view"

    assert LibraryPaths.read_path("/tags/3-must-view", %{}) ==
             {filters(%{"tag" => "3", "status" => "inbox"}), nil}

    assert LibraryPaths.read_path("/tags/3-x/history/4056-y", %{}) ==
             {filters(%{"tag" => "3", "status" => "heard"}), "4056"}

    assert LibraryPaths.read_path("/tags/3-x/4056-y", %{}) ==
             {filters(%{"tag" => "3", "status" => "inbox"}), "4056"}

    assert LibraryPaths.place?(filters(%{"tag" => "3", "status" => "inbox"}), "tag", "3")
    refute LibraryPaths.place?(filters(%{"tag" => "3", "status" => "inbox"}), "status", "inbox")
  end

  test "an item follows the list it is shown in" do
    assert LibraryPaths.library_path(filters(%{"status" => "inbox"}), @item) ==
             "/inbox/4056-ki-verfassung-die-irre-selbstkontrolle-der-tech-bros"

    assert LibraryPaths.library_path(
             filters(%{"source" => "106", "status" => "inbox"}),
             @item,
             @feeds
           ) ==
             "/feeds/106-metacheles-tonspur/4056-ki-verfassung-die-irre-selbstkontrolle-der-tech-bros"

    assert LibraryPaths.library_path(filters(%{"source" => "106"}), 4056, @feeds) ==
             "/feeds/106-metacheles-tonspur/all/4056"

    assert LibraryPaths.library_path(filters(%{"status" => "heard"}), 12) == "/history/12"
  end

  test "a search stays in the query" do
    assert LibraryPaths.library_path(filters(%{"status" => "inbox", "q" => "akku"})) ==
             "/inbox?q=akku"
  end

  test "a title becomes letters, digits and dashes" do
    assert LibraryPaths.slug("Großbatteriespeicher: Nützlich, netzdienlich (& mehr)!") ==
             "grossbatteriespeicher-nuetzlich-netzdienlich-mehr"

    assert LibraryPaths.slug("Ça va? Élan") == "ca-va-elan"
    assert LibraryPaths.slug("🚨 !!!") == ""
    assert String.length(LibraryPaths.slug(String.duplicate("long words ", 40))) <= 60
  end

  # / opens the account's start page. Without one it opens the queue.
  test "the root reads into the start page's filters" do
    alias Sikio.Preferences.Preference

    assert LibraryPaths.start_filters(%Preference{}) == %{"status" => "queue"}
    assert LibraryPaths.start_filters(%Preference{start_view: "inbox"}) == %{"status" => "inbox"}

    assert LibraryPaths.start_filters(%Preference{start_view: "inbox", start_tag_id: 3}) ==
             %{"tag" => "3", "status" => "inbox"}

    assert LibraryPaths.read_path("/", %{}, %{"tag" => "3", "status" => "inbox"}) ==
             {filters(%{"tag" => "3", "status" => "inbox"}), nil}
  end

  test "an address reads back into the filters and the item" do
    assert LibraryPaths.read_path("/", %{}) == {filters(%{"status" => "queue"}), nil}
    assert LibraryPaths.read_path("/inbox", %{}) == {filters(%{"status" => "inbox"}), nil}
    assert LibraryPaths.read_path("/all", %{}) == {@none, nil}

    assert LibraryPaths.read_path("/queue/4056-ki", %{"q" => "akku", "kind" => "audio"}) ==
             {filters(%{"status" => "queue", "q" => "akku"}), "4056"}

    assert LibraryPaths.read_path("/feeds/106-metacheles-tonspur", %{}) ==
             {filters(%{"source" => "106", "status" => "inbox"}), nil}

    assert LibraryPaths.read_path("/feeds/106-metacheles-tonspur/all", %{}) ==
             {filters(%{"source" => "106"}), nil}

    assert LibraryPaths.read_path("/feeds/106-x/all/4056-y", %{}) ==
             {filters(%{"source" => "106"}), "4056"}

    assert LibraryPaths.read_path("/feeds/106-x/inbox", %{"q" => "akku"}) ==
             {filters(%{"source" => "106", "status" => "inbox", "q" => "akku"}), nil}

    assert LibraryPaths.read_path("/feeds/106-x/4056-y", %{}) ==
             {filters(%{"source" => "106", "status" => "inbox"}), "4056"}

    assert LibraryPaths.read_path("/feeds/106/history/4056", %{}) ==
             {filters(%{"source" => "106", "status" => "heard"}), "4056"}
  end

  # Paths from before the inbox existed map to the current lists.
  test "the old addresses read as the lists they meant" do
    assert LibraryPaths.read_path("/new", %{}) == {filters(%{"status" => "inbox"}), nil}

    assert LibraryPaths.read_path("/in-progress/4056-ki", %{}) ==
             {filters(%{"status" => "queue"}), "4056"}

    assert LibraryPaths.read_path("/completed", %{}) == {filters(%{"status" => "heard"}), nil}

    assert LibraryPaths.read_path("/feeds/106-x/completed", %{}) ==
             {filters(%{"source" => "106", "status" => "heard"}), nil}

    assert LibraryPaths.read_path("/feeds/106-x/new", %{}) ==
             {filters(%{"source" => "106", "status" => "inbox"}), nil}
  end

  test "an address that names no item or source by number names none" do
    assert LibraryPaths.read_path("/inbox/ki-verfassung", %{}) ==
             {filters(%{"status" => "inbox"}), :invalid}

    assert LibraryPaths.read_path("/feeds/metacheles", %{}) ==
             {filters(%{"source" => "", "status" => "inbox"}), nil}
  end
end
