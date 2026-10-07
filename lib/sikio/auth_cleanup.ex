# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.AuthCleanup do
  @moduledoc "Explicit auth maintenance. The application chooses when to schedule it."
  alias Ithibati.Identity.Challenges
  alias Ithibati.Identity.Invitations
  alias Ithibati.Web.Gate

  def run do
    %{
      # Through the endpoint, so LiveView sockets of expired sessions are disconnected too.
      sessions: Gate.expire(SikioWeb.Endpoint),
      challenges: Challenges.delete_expired(),
      invitations: Invitations.delete_expired()
    }
  end
end
