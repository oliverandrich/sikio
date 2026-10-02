# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.MediaComponentsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import SikioWeb.MediaComponents

  defp entry(kind, playback \\ nil), do: %{feed: %{kind: kind}, playback: playback}

  # A PeerTube video is watched, not listened to. The wording followed a single comparison
  # against YouTube, so a third kind of video would have been described as an episode.
  describe "wording for a kind that is video but not YouTube" do
    test "a finished video was watched" do
      assert status_label(entry(:peertube, %{status: :completed})) == "Watched"
      assert status_label(entry(:podcast, %{status: :completed})) == "Listened"
    end

    test "marking one uses the verb that fits what it is" do
      assert mark_done_label(entry(:peertube)) == "Mark as watched"
      assert mark_new_label(entry(:peertube)) == "Mark as unwatched"
    end

    test "its own name, not YouTube's and not a podcast's" do
      assert kind_label(entry(:peertube)) == "PeerTube video"
      assert kind_label(entry(:youtube)) == "YouTube video"
      assert kind_label(entry(:podcast)) == "Podcast episode"
    end
  end

  # A runtime is read at a glance in a list, so an hour gets its own place and nothing else does.
  describe "runtime/1" do
    test "minutes and seconds, and hours only when there are any" do
      assert runtime(2900) == "48:20"
      assert runtime(4325) == "1:12:05"
      assert runtime(59) == "0:59"
    end

    # A player measures its media in fractions of a second.
    test "a measured length counts whole seconds" do
      assert runtime(3723.6) == "1:02:03"
      assert runtime(59.9) == "0:59"
    end

    test "a runtime nobody stated is no runtime" do
      assert runtime(nil) == nil
    end
  end

  # A failed refresh is stored as its reason. The reader is told what it means, in a sentence.
  describe "refresh_problem/1" do
    test "says what went wrong in words, and something general for the rest" do
      assert refresh_problem("invalid_feed") =~ "no longer serves a feed"
      assert refresh_problem("too_large") =~ "larger"
      assert refresh_problem("too_many_redirects") =~ "redirects"
      assert refresh_problem("unsafe_url") =~ "does not fetch"
      assert refresh_problem("gone") =~ "no longer exists"
      assert refresh_problem("unavailable") =~ "could not be reached"
      assert refresh_problem("something new") =~ "could not be reached"
    end
  end

  # A row has little room, and the source's kind is all it needs to say.
  describe "medium_label/1" do
    test "names the platform or the podcast, nothing more" do
      assert medium_label(%{feed: %{kind: :youtube}}) == "YouTube"
      assert medium_label(%{feed: %{kind: :peertube}}) == "PeerTube"
      assert medium_label(%{feed: %{kind: :podcast}}) == "Podcast"
    end
  end

  # A date sits in translated text, so its month is translated too.
  describe "date/1" do
    test "names the month in the reader's language" do
      published = ~U[2026-09-18 09:00:00Z]
      assert date(published) == "18 Sep 2026"

      Gettext.with_locale(SikioWeb.Gettext, "de", fn ->
        assert date(published) == "18. Sept. 2026"
      end)
    end
  end

  # A list is mostly this year, so it leaves the year out until it differs.
  describe "short_date/2" do
    test "drops the year of this year and keeps any other" do
      today = ~D[2026-10-02]
      assert short_date(~U[2026-09-18 09:00:00Z], today) == "18 Sep"
      assert short_date(~U[2025-12-24 09:00:00Z], today) == "24 Dec 2025"

      Gettext.with_locale(SikioWeb.Gettext, "de", fn ->
        assert short_date(~U[2026-09-18 09:00:00Z], today) == "18. Sept."
      end)
    end
  end
end
