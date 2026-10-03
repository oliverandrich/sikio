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

  test "a list by status is its own path, and new is the library's front" do
    assert Sidebar.library_path(filters(%{"status" => "new"})) == "/new"
    assert Sidebar.library_path(filters(%{"status" => "in_progress"})) == "/in-progress"
    assert Sidebar.library_path(filters(%{"status" => "completed"})) == "/completed"
    assert Sidebar.library_path(@none) == "/all"
  end

  # Like the library's front, a source opens on what is new. Every item is a place of its own.
  test "a source is named by its number and its title, and opens on what is new" do
    assert Sidebar.library_path(filters(%{"source" => "106", "status" => "new"}), nil, @feeds) ==
             "/feeds/106-metacheles-tonspur"

    assert Sidebar.library_path(filters(%{"source" => "106"}), nil, @feeds) ==
             "/feeds/106-metacheles-tonspur/all"

    assert Sidebar.library_path(
             filters(%{"source" => "106", "status" => "completed"}),
             nil,
             @feeds
           ) ==
             "/feeds/106-metacheles-tonspur/completed"

    assert Sidebar.library_path(filters(%{"source" => "7", "status" => "new"})) == "/feeds/7",
           "a source without a known title keeps its number alone"

    assert Sidebar.place_path("source", "106", @feeds) == "/feeds/106-metacheles-tonspur"
  end

  # A tag is a place like a source, named by its number and its name, and opens on what is new.
  test "a tag is named by its number and its name, and opens on what is new" do
    tags = %{{:tag, 3} => "Must view"}

    assert Sidebar.library_path(filters(%{"tag" => "3", "status" => "new"}), nil, tags) ==
             "/tags/3-must-view"

    assert Sidebar.library_path(filters(%{"tag" => "3"}), nil, tags) == "/tags/3-must-view/all"

    assert Sidebar.library_path(filters(%{"tag" => "3", "status" => "new"}), @item, tags) ==
             "/tags/3-must-view/4056-ki-verfassung-die-irre-selbstkontrolle-der-tech-bros"

    assert Sidebar.place_path("tag", "3", tags) == "/tags/3-must-view"

    assert Sidebar.read_path("/tags/3-must-view", %{}) ==
             {filters(%{"tag" => "3", "status" => "new"}), nil}

    assert Sidebar.read_path("/tags/3-x/completed/4056-y", %{}) ==
             {filters(%{"tag" => "3", "status" => "completed"}), "4056"}

    assert Sidebar.read_path("/tags/3-x/4056-y", %{}) ==
             {filters(%{"tag" => "3", "status" => "new"}), "4056"}

    assert Sidebar.place?(filters(%{"tag" => "3", "status" => "new"}), "tag", "3")
    refute Sidebar.place?(filters(%{"tag" => "3", "status" => "new"}), "status", "new")
  end

  test "an item follows the list it is shown in" do
    assert Sidebar.library_path(filters(%{"status" => "new"}), @item) ==
             "/new/4056-ki-verfassung-die-irre-selbstkontrolle-der-tech-bros"

    assert Sidebar.library_path(filters(%{"source" => "106", "status" => "new"}), @item, @feeds) ==
             "/feeds/106-metacheles-tonspur/4056-ki-verfassung-die-irre-selbstkontrolle-der-tech-bros"

    assert Sidebar.library_path(filters(%{"source" => "106"}), 4056, @feeds) ==
             "/feeds/106-metacheles-tonspur/all/4056"

    assert Sidebar.library_path(filters(%{"status" => "completed"}), 12) == "/completed/12"
  end

  test "a search stays in the query" do
    assert Sidebar.library_path(filters(%{"status" => "new", "q" => "akku"})) == "/new?q=akku"
  end

  test "a title becomes letters, digits and dashes" do
    assert Sidebar.slug("Großbatteriespeicher: Nützlich, netzdienlich (& mehr)!") ==
             "grossbatteriespeicher-nuetzlich-netzdienlich-mehr"

    assert Sidebar.slug("Ça va? Élan") == "ca-va-elan"
    assert Sidebar.slug("🚨 !!!") == ""
    assert String.length(Sidebar.slug(String.duplicate("long words ", 40))) <= 60
  end

  test "an address reads back into the filters and the item" do
    assert Sidebar.read_path("/", %{}) == {filters(%{"status" => "new"}), nil}
    assert Sidebar.read_path("/new", %{}) == {filters(%{"status" => "new"}), nil}
    assert Sidebar.read_path("/all", %{}) == {@none, nil}

    assert Sidebar.read_path("/in-progress/4056-ki", %{"q" => "akku", "kind" => "audio"}) ==
             {filters(%{"status" => "in_progress", "q" => "akku"}), "4056"}

    assert Sidebar.read_path("/feeds/106-metacheles-tonspur", %{}) ==
             {filters(%{"source" => "106", "status" => "new"}), nil}

    assert Sidebar.read_path("/feeds/106-metacheles-tonspur/all", %{}) ==
             {filters(%{"source" => "106"}), nil}

    assert Sidebar.read_path("/feeds/106-x/all/4056-y", %{}) ==
             {filters(%{"source" => "106"}), "4056"}

    assert Sidebar.read_path("/feeds/106-x/new", %{"q" => "akku"}) ==
             {filters(%{"source" => "106", "status" => "new", "q" => "akku"}), nil}

    assert Sidebar.read_path("/feeds/106-x/4056-y", %{}) ==
             {filters(%{"source" => "106", "status" => "new"}), "4056"}

    assert Sidebar.read_path("/feeds/106/completed/4056", %{}) ==
             {filters(%{"source" => "106", "status" => "completed"}), "4056"}
  end

  test "an address that names no item or source by number names none" do
    assert Sidebar.read_path("/new/ki-verfassung", %{}) ==
             {filters(%{"status" => "new"}), :invalid}

    assert Sidebar.read_path("/feeds/metacheles", %{}) ==
             {filters(%{"source" => "", "status" => "new"}), nil}
  end
end
