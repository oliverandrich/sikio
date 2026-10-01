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

    test "a runtime nobody stated is no runtime" do
      assert runtime(nil) == nil
    end
  end
end
