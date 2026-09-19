defmodule Sikio.AuthCleanup do
  @moduledoc "Explicit auth maintenance. The application chooses when to schedule it."
  alias Ithibati.Identity.Challenges
  alias Ithibati.Identity.Invitations
  alias Ithibati.Identity.Sessions

  def run do
    %{
      sessions: Sessions.delete_expired(),
      challenges: Challenges.delete_expired(),
      invitations: Invitations.delete_expired()
    }
  end
end
