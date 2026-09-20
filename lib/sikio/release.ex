# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Release do
  @moduledoc """
  Explicit entry points an operator runs against an assembled release.

  Each starts the application's repository and nothing else, so one may be run beside a server
  without binding a second port or waking the workers.
  """
  alias Ithibati.Identity.Instance

  @app :sikio

  def migrate do
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Issues the code that lets somebody claim this instance, and prints it once.

  The code exists in one place for one moment: this output. Only its digest is stored, so an
  operator who loses it issues another, and issuing another is what makes the previous one
  worthless. Nothing writes it to a log, a file or a response.

  An instance that already has an account needs no code, and neither does one that does not
  protect its claim. Printing one nobody could spend would read like the command had worked.
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

      {:error, :claim_is_open} = error ->
        IO.puts("This instance leaves its claim open, so no code is needed to make the first")
        IO.puts("account. See docs/operations.md for what protecting it requires.")
        error

      {:error, reason} = error ->
        IO.puts("No code was issued: #{inspect(reason)}")
        error
    end
  end

  @doc "`setup_code/0` for a shell, which reads an exit status rather than a return value."
  def setup_code! do
    case setup_code() do
      :ok -> :ok
      _error -> System.halt(1)
    end
  end

  # The library states the requirement by raising, which is the right answer to a library being
  # used wrongly and the wrong one to hand somebody who typed a command. Only that one call is
  # caught: `Config.repo/0` and the repository configuration raise the same kind of error and
  # mean something else, and answering those with "the claim is open" points at the wrong key.
  defp issue do
    with_repo(fn ->
      try do
        Instance.issue_code()
      rescue
        ArgumentError -> {:error, :claim_is_open}
      end
    end)
  end

  def rollback(repo, version) do
    Application.load(@app)
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
    :ok
  end

  # The repository, started for the length of one call and stopped after. The same thing
  # `migrate/0` leans on, which is why neither wakes an endpoint or a queue.
  defp with_repo(fun) do
    Application.load(@app)
    repo = hd(Application.fetch_env!(@app, :ecto_repos))

    case Ecto.Migrator.with_repo(repo, fn _repo -> fun.() end) do
      {:ok, result, _started} -> result
      other -> other
    end
  end
end
