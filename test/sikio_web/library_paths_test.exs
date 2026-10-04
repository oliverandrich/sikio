# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.LibraryPathsTest do
  @moduledoc """
  The library's addresses: a list on screen and the item in it, as paths.

  The library works on filters by status, source, tag and search. Only how they are spelled
  in an address is decided here, both ways.
  """
  use ExUnit.Case, async: true

  alias SikioWeb.Sidebar

  @none %{"status" => "", "source" => "", "tag" => "", "q" => ""}
  @feeds %{106 => "MeTacheles Tonspur"}
  @item %{id: 4056, title: "KI-Verfassung - Die irre Selbstkontrolle der Tech-Bros"}

  defp filters(changes), do: Map.merge(@none, changes)

  test "a list by status is its own path, and the inbox is the library's front" do
    assert Sidebar.library_path(filters(%{"status" => "inbox"})) == "/inbox"
    assert Sidebar.library_path(filters(%{"status" => "queue"})) == "/queue"
    assert Sidebar.library_path(filters(%{"status" => "heard"})) == "/history"
    assert Sidebar.library_path(@none) == "/all"
  end

  # Like the library's front, a source opens on its inbox. Every item is a place of its own.
  test "a source is named by its number and its title, and opens on its inbox" do
    assert Sidebar.library_path(filters(%{"source" => "106", "status" => "inbox"}), nil, @feeds) ==
             "/feeds/106-metacheles-tonspur"

    assert Sidebar.library_path(filters(%{"source" => "106"}), nil, @feeds) ==
             "/feeds/106-metacheles-tonspur/all"

    assert Sidebar.library_path(
             filters(%{"source" => "106", "status" => "heard"}),
             nil,
             @feeds
           ) ==
             "/feeds/106-metacheles-tonspur/history"

    assert Sidebar.library_path(filters(%{"source" => "7", "status" => "inbox"})) == "/feeds/7",
           "a source without a known title keeps its number alone"

    assert Sidebar.place_path("source", "106", @feeds) == "/feeds/106-metacheles-tonspur"
  end

  # A tag is a place like a source, named by its number and its name, and opens on its inbox.
  test "a tag is named by its number and its name, and opens on its inbox" do
    tags = %{{:tag, 3} => "Must view"}

    assert Sidebar.library_path(filters(%{"tag" => "3", "status" => "inbox"}), nil, tags) ==
             "/tags/3-must-view"

    assert Sidebar.library_path(filters(%{"tag" => "3"}), nil, tags) == "/tags/3-must-view/all"

    assert Sidebar.library_path(filters(%{"tag" => "3", "status" => "inbox"}), @item, tags) ==
             "/tags/3-must-view/4056-ki-verfassung-die-irre-selbstkontrolle-der-tech-bros"

    assert Sidebar.place_path("tag", "3", tags) == "/tags/3-must-view"

    assert Sidebar.read_path("/tags/3-must-view", %{}) ==
             {filters(%{"tag" => "3", "status" => "inbox"}), nil}

    assert Sidebar.read_path("/tags/3-x/history/4056-y", %{}) ==
             {filters(%{"tag" => "3", "status" => "heard"}), "4056"}

    assert Sidebar.read_path("/tags/3-x/4056-y", %{}) ==
             {filters(%{"tag" => "3", "status" => "inbox"}), "4056"}

    assert Sidebar.place?(filters(%{"tag" => "3", "status" => "inbox"}), "tag", "3")
    refute Sidebar.place?(filters(%{"tag" => "3", "status" => "inbox"}), "status", "inbox")
  end

  test "an item follows the list it is shown in" do
    assert Sidebar.library_path(filters(%{"status" => "inbox"}), @item) ==
             "/inbox/4056-ki-verfassung-die-irre-selbstkontrolle-der-tech-bros"

    assert Sidebar.library_path(filters(%{"source" => "106", "status" => "inbox"}), @item, @feeds) ==
             "/feeds/106-metacheles-tonspur/4056-ki-verfassung-die-irre-selbstkontrolle-der-tech-bros"

    assert Sidebar.library_path(filters(%{"source" => "106"}), 4056, @feeds) ==
             "/feeds/106-metacheles-tonspur/all/4056"

    assert Sidebar.library_path(filters(%{"status" => "heard"}), 12) == "/history/12"
  end

  test "a search stays in the query" do
    assert Sidebar.library_path(filters(%{"status" => "inbox", "q" => "akku"})) == "/inbox?q=akku"
  end

  test "a title becomes letters, digits and dashes" do
    assert Sidebar.slug("Großbatteriespeicher: Nützlich, netzdienlich (& mehr)!") ==
             "grossbatteriespeicher-nuetzlich-netzdienlich-mehr"

    assert Sidebar.slug("Ça va? Élan") == "ca-va-elan"
    assert Sidebar.slug("🚨 !!!") == ""
    assert String.length(Sidebar.slug(String.duplicate("long words ", 40))) <= 60
  end

  test "an address reads back into the filters and the item" do
    assert Sidebar.read_path("/", %{}) == {filters(%{"status" => "inbox"}), nil}
    assert Sidebar.read_path("/inbox", %{}) == {filters(%{"status" => "inbox"}), nil}
    assert Sidebar.read_path("/all", %{}) == {@none, nil}

    assert Sidebar.read_path("/queue/4056-ki", %{"q" => "akku", "kind" => "audio"}) ==
             {filters(%{"status" => "queue", "q" => "akku"}), "4056"}

    assert Sidebar.read_path("/feeds/106-metacheles-tonspur", %{}) ==
             {filters(%{"source" => "106", "status" => "inbox"}), nil}

    assert Sidebar.read_path("/feeds/106-metacheles-tonspur/all", %{}) ==
             {filters(%{"source" => "106"}), nil}

    assert Sidebar.read_path("/feeds/106-x/all/4056-y", %{}) ==
             {filters(%{"source" => "106"}), "4056"}

    assert Sidebar.read_path("/feeds/106-x/inbox", %{"q" => "akku"}) ==
             {filters(%{"source" => "106", "status" => "inbox", "q" => "akku"}), nil}

    assert Sidebar.read_path("/feeds/106-x/4056-y", %{}) ==
             {filters(%{"source" => "106", "status" => "inbox"}), "4056"}

    assert Sidebar.read_path("/feeds/106/history/4056", %{}) ==
             {filters(%{"source" => "106", "status" => "heard"}), "4056"}
  end

  # Addresses from before the inbox still lead to the lists they meant.
  test "the old addresses read as the lists they meant" do
    assert Sidebar.read_path("/new", %{}) == {filters(%{"status" => "inbox"}), nil}

    assert Sidebar.read_path("/in-progress/4056-ki", %{}) ==
             {filters(%{"status" => "queue"}), "4056"}

    assert Sidebar.read_path("/completed", %{}) == {filters(%{"status" => "heard"}), nil}

    assert Sidebar.read_path("/feeds/106-x/completed", %{}) ==
             {filters(%{"source" => "106", "status" => "heard"}), nil}

    assert Sidebar.read_path("/feeds/106-x/new", %{}) ==
             {filters(%{"source" => "106", "status" => "inbox"}), nil}
  end

  test "an address that names no item or source by number names none" do
    assert Sidebar.read_path("/inbox/ki-verfassung", %{}) ==
             {filters(%{"status" => "inbox"}), :invalid}

    assert Sidebar.read_path("/feeds/metacheles", %{}) ==
             {filters(%{"source" => "", "status" => "inbox"}), nil}
  end
end
