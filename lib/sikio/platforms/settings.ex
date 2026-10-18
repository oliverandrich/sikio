# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Platforms.Settings do
  @moduledoc "The instance's one row of settings: which platforms members may add from."
  use Ecto.Schema

  schema "instance_settings" do
    field :podcast, :boolean, default: true
    field :youtube, :boolean, default: true
    field :peertube, :boolean, default: true
    field :mediathek, :boolean, default: true
  end
end
