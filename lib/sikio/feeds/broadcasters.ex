# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Feeds.Broadcasters do
  @moduledoc """
  The websites of the broadcasters MediathekViewWeb lists, by its channel names.

  A TV series is the search for a topic on a channel, so its feed address names the channel.
  The website names the broadcaster's icon, which stands in for the series' missing picture.
  Broadcasters whose site names no raster icon or answers 403 are left out, so their series show
  their initial. Checked on 2026-10-11: arte, NDR, ONE, Radio Bremen and SR.
  """

  alias Sikio.Feeds.Parser

  @sites %{
    "ard" => "https://www.daserste.de",
    "ard-alpha" => "https://www.ardalpha.de",
    "br" => "https://www.br.de",
    "dw" => "https://www.dw.com",
    "funk.net" => "https://www.funk.net",
    "hr" => "https://www.hr.de",
    "kika" => "https://www.kika.de",
    "mdr" => "https://www.mdr.de",
    "orf" => "https://on.orf.at",
    "phoenix" => "https://www.phoenix.de",
    "rbb" => "https://www.rbb-online.de",
    "srf" => "https://www.srf.ch",
    "swr" => "https://www.swr.de",
    "tagesschau24" => "https://www.tagesschau.de",
    "wdr" => "https://www1.wdr.de",
    "zdf" => "https://www.zdf.de",
    "zdf-tivi" => "https://www.zdf.de",
    "3sat" => "https://www.3sat.de"
  }

  @doc "Returns the website of the broadcaster a series' feed address names, or nil."
  def site(feed_url) when is_binary(feed_url) do
    case Parser.mediathek_selector(feed_url) do
      {["!" <> channel | _], _topics} -> Map.get(@sites, String.downcase(channel))
      _none -> nil
    end
  end

  def site(_feed_url), do: nil
end
