# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Platforms do
  @moduledoc """
  Which platforms members may add sources and items from: podcasts, YouTube, PeerTube and the
  Mediathek. An administrator switches each one; all are on by default.

  A platform that is off offers no search and refuses new subscriptions and saved items. Existing
  subscriptions keep refreshing and playing. The platforms are the feed kinds of
  `Sikio.Feeds.Feed`.
  """
  alias Sikio.Accounts
  alias Sikio.Platforms.Settings
  alias Sikio.Repo

  @kinds [:podcast, :youtube, :peertube, :mediathek]

  @doc "Returns the platforms, in display order."
  def kinds, do: @kinds

  @doc "Returns each platform with whether it is on."
  def enabled, do: Map.take(settings(), @kinds)

  @doc "Returns whether the platform of feed kind `kind` is on."
  def enabled?(kind) when kind in @kinds, do: Map.fetch!(settings(), kind)

  @doc "Returns `:ok` when the platform of feed kind `kind` is on, else `{:error, :platform_off}`."
  def allow(kind), do: if(enabled?(kind), do: :ok, else: {:error, :platform_off})

  @doc """
  Switches the platform of feed kind `kind` on or off, for an administrator.

  Returns `{:ok, enabled}` with every platform's state, `{:error, :forbidden}` unless `admin` is
  one, or `{:error, :unknown}` for a kind that is no platform.
  """
  def set(admin, kind, on?) when kind in @kinds and is_boolean(on?) do
    Accounts.with_admin(admin, fn _admins ->
      with {:ok, settings} <-
             settings() |> Ecto.Changeset.change(%{kind => on?}) |> Repo.insert_or_update(),
           do: {:ok, Map.take(settings, @kinds)}
    end)
  end

  def set(_admin, _kind, _on?), do: {:error, :unknown}

  # The first change writes the only row, under id 1. Until then every platform is on.
  defp settings, do: Repo.get(Settings, 1) || %Settings{id: 1}
end
