# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.BroadcastersTest do
  use ExUnit.Case, async: true

  alias Sikio.Feeds.Broadcasters

  # A TV series is the search for a topic on a channel. The channel names the broadcaster.
  test "a series' channel leads to its broadcaster's website" do
    feed = fn query ->
      "https://mediathekviewweb.de/feed?" <> URI.encode_query(%{query: query, size: 20})
    end

    assert Broadcasters.site(feed.("!WDR #Tatort")) == "https://www1.wdr.de"
    assert Broadcasters.site(feed.("!ard #Die,Sendung,mit,der,Maus")) == "https://www.daserste.de"
    assert Broadcasters.site(feed.("!3Sat #Kulturzeit")) == "https://www.3sat.de"
    assert Broadcasters.site(feed.("!Unbekannt #Etwas")) == nil
    assert Broadcasters.site(feed.("#Ohne,Sender")) == nil
    assert Broadcasters.site("https://example.org/rss") == nil
  end
end
