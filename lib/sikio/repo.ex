defmodule Sikio.Repo do
  use Ecto.Repo,
    otp_app: :sikio,
    adapter: Ecto.Adapters.Postgres
end
