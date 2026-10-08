# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Preferences do
  @moduledoc """
  An account's preferences: the start page, Play on and the interface language.
  """
  import Ecto.Query

  alias Sikio.Accounts.User
  alias Sikio.Preferences.Preference
  alias Sikio.Repo
  alias Sikio.Tags.Tag

  @doc "Whether the player continues with the queue when an item ends. Defaults to true."
  def play_on?(%User{id: user_id}),
    do: Repo.one(from p in Preference, where: p.user_id == ^user_id, select: p.play_on) != false

  @doc "Returns the account's chosen interface language, or nil for the browser's."
  def locale(%User{id: user_id}),
    do: Repo.one(from p in Preference, where: p.user_id == ^user_id, select: p.locale)

  @doc "Returns the account's preferences, or the defaults for an account without a row."
  def get(%User{id: user_id}),
    do: Repo.get_by(Preference, user_id: user_id) || %Preference{user_id: user_id}

  @doc """
  Saves the given preferences and keeps the others.
  Returns `{:ok, preference}` or `{:error, changeset}`.
  A start tag must be one of the account's tags. A blank language follows the browser again.
  """
  def update(%User{} = account, attrs) do
    account
    |> get()
    |> Preference.changeset(attrs, locales())
    |> Ecto.Changeset.validate_change(:start_tag_id, fn :start_tag_id, id ->
      if own_tag?(account, id), do: [], else: [start_tag_id: "is not one of your tags"]
    end)
    |> save()
  end

  # A first save inserts. Another first save may win the race, so a conflict updates its row.
  defp save(%{data: %{id: nil}} = changeset) do
    Repo.insert(changeset,
      on_conflict: {:replace, [:updated_at | Map.keys(changeset.changes)]},
      conflict_target: :user_id,
      returning: true
    )
  end

  defp save(changeset), do: Repo.update(changeset)

  defp own_tag?(%User{id: user_id}, id),
    do: Repo.exists?(from t in Tag, where: t.id == ^id and t.user_id == ^user_id)

  @doc "Returns the supported interface languages."
  def locales, do: Application.get_env(:sikio, :locales, ~w(en de))
end
