# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Release do
  @moduledoc """
  Commands an operator runs against an assembled release.

  Each starts only the repository, not the application. One can run beside a server without
  binding a second port or starting Oban.
  """
  alias Ithibati.Identity.Instance
  alias Sikio.Claim

  @app :sikio

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Issues a setup code for claiming this instance and prints it to stdout once.

  Only its digest is stored. A lost code cannot be shown again; issue a new one instead.
  Issuing a new code invalidates the previous one. This function writes it nowhere else.

  Returns `{:error, :already_claimed}` without a code when an account exists.
  Printing a code nobody can use would look like success.
  """
  def setup_code do
    case issue() do
      {:ok, code} ->
        IO.puts("Enter this once, on the site, to claim the instance. It is shown only here.")
        IO.puts(code)
        :ok

      {:error, :already_claimed} = error ->
        IO.puts("This instance is already claimed. No code was issued and none is needed.")
        error

      {:error, reason} = error ->
        IO.puts("No code was issued: #{inspect(reason)}")
        error
    end
  end

  @doc "Runs `setup_code/0` and halts with exit status 1 on error, for shell scripts."
  def setup_code! do
    case setup_code() do
      :ok -> :ok
      _error -> System.halt(1)
    end
  end

  # `eval` loads the configuration but starts no application, so the start-up check does not run.
  # Without this call, Ithibati returns `:claim_is_open`, which does not name the key to change.
  defp issue do
    Claim.verify!()
    with_repo(&Instance.issue_code/0)
  end

  def rollback(repo, version) do
    Application.load(@app)
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  # Starts the repository for one call and stops it afterwards, as `migrate/0` does.
  # Neither starts the endpoint or Oban.
  defp with_repo(fun) do
    Application.load(@app)
    repo = hd(Application.fetch_env!(@app, :ecto_repos))

    case Ecto.Migrator.with_repo(repo, fn _repo -> fun.() end) do
      {:ok, result, _started} -> result
      other -> other
    end
  end
end
