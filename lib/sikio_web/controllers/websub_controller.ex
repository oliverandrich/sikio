# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule SikioWeb.WebSubController do
  @moduledoc """
  The WebSub callback at `/websub/:token`; see `Sikio.Feeds.Hub`.

  The hub verifies a subscription with a GET and pushes new content with a signed POST.
  A push only brings its feed's next check forward. The refresh reads the feed itself.
  """
  use SikioWeb, :controller

  require Logger

  alias Sikio.Feeds.Hub

  # YouTube pushes one entry of a few kilobytes. A larger body is not a push.
  @max_body 1_000_000

  def verify(conn, %{"token" => token, "hub.mode" => "subscribe"} = params) do
    lease = lease(params["hub.lease_seconds"])

    case Hub.verify(token, params["hub.topic"], lease) do
      {:ok, subscription} ->
        Logger.info("websub subscription verified", feed_id: subscription.feed_id)
        text(conn, params["hub.challenge"] || "")

      :error ->
        send_resp(conn, 404, "")
    end
  end

  def verify(conn, %{"token" => token, "hub.mode" => "denied"} = params) do
    case Hub.deny(token, params["hub.topic"]) do
      {:ok, subscription} ->
        Logger.notice("websub subscription denied",
          feed_id: subscription.feed_id,
          reason: params["hub.reason"]
        )

        send_resp(conn, 200, "")

      :error ->
        send_resp(conn, 404, "")
    end
  end

  # Sikio never asks to unsubscribe, so such a request is not its own.
  def verify(conn, _params), do: send_resp(conn, 404, "")

  # A wrong signature or an unverified subscription is acknowledged and ignored, as the spec
  # allows. A dropped token answers 410, which may end the subscription at the hub.
  def push(conn, %{"token" => token}) do
    with {:ok, body, conn} <- read_body(conn, length: @max_body),
         %{} = subscription <- Hub.by_token(token) do
      if subscription.state == :active and Hub.authentic?(subscription, signature(conn), body) do
        Hub.announce(subscription, video_id(body))
      end

      send_resp(conn, 204, "")
    else
      {:more, _partial, conn} -> send_resp(conn, 413, "")
      nil -> send_resp(conn, 410, "")
      {:error, _reason} -> send_resp(conn, 400, "")
    end
  end

  defp signature(conn), do: conn |> get_req_header("x-hub-signature") |> List.first()

  # A YouTube video id has eleven characters. A push without one only brings the check forward.
  defp video_id(body) do
    case Regex.run(~r"<yt:videoId>([A-Za-z0-9_-]{11})</yt:videoId>", body) do
      [_match, id] -> id
      nil -> nil
    end
  end

  defp lease(value) do
    case Integer.parse(value || "") do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> nil
    end
  end
end
