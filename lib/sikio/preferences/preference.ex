# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Preferences.Preference do
  @moduledoc """
  One account's preferences. An account without a row uses the defaults.

  The users table follows Ithibati Starter, so Sikio-specific settings live in a separate table.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Sikio.Accounts.User
  alias Sikio.Tags.Tag

  @start_views ~w(queue inbox)

  schema "preferences" do
    belongs_to :user, User
    # Whether the player continues with the queue when an item ends.
    field :play_on, :boolean, default: true
    # The list the library opens on. A start tag takes precedence over it.
    field :start_view, :string, default: "queue"
    belongs_to :start_tag, Tag
    # The interface language. Nil follows the browser's `Accept-Language`.
    field :locale, :string
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Returns the lists that `start_view` names."
  def start_views, do: @start_views

  @doc "Casts and validates the preferences. `locales` are the supported language codes."
  def changeset(preference, attrs, locales) do
    preference
    |> cast(attrs, [:play_on, :start_view, :start_tag_id, :locale])
    |> validate_required([:play_on, :start_view])
    |> validate_inclusion(:start_view, @start_views)
    |> validate_inclusion(:locale, locales)
    |> foreign_key_constraint(:start_tag_id)
  end
end
