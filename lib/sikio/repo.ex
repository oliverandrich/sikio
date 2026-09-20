# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo do
  use Ecto.Repo,
    otp_app: :sikio,
    adapter: Ecto.Adapters.Postgres
end
