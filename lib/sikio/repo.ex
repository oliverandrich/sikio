# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo do
  @moduledoc """
  The application's database: SQLite or Postgres, whichever the build was compiled for.
  """
  use Ecto.Repo,
    otp_app: :sikio,
    adapter:
      (case Application.compile_env!(:sikio, :database) do
         :sqlite -> Ecto.Adapters.SQLite3
         :postgres -> Ecto.Adapters.Postgres
       end)
end
