# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Library.TransferImport do
  @moduledoc """
  Imports an exported library for one account, see `Sikio.Library.Transfer.restore/2`.

  An import fetches every source and may take minutes, so it runs here rather than in a page.
  The import page receives the result through `Sikio.Library.Events.imported/2`.
  One attempt suffices: a second run of the same file changes nothing the first one applied.
  """
  # One import per account waits or runs at a time. An import holds its slot for minutes, so it
  # has a queue of its own and leaves `feeds` to polling.
  use Oban.Worker,
    queue: :imports,
    max_attempts: 1,
    unique: [period: :infinity, keys: [:user_id], states: [:available, :scheduled, :executing]]

  alias Sikio.Accounts.User
  alias Sikio.Library.Events
  alias Sikio.Library.Transfer
  alias Sikio.Repo

  @impl true
  def perform(%Oban.Job{args: %{"user_id" => user_id, "document" => json}}) do
    with %User{} = account <- Repo.get(User, user_id),
         {:ok, document} <- Transfer.parse(json) do
      restore(account, document)
    else
      nil -> {:cancel, :account_gone}
      {:error, reason} -> {:cancel, reason}
    end
  end

  # The page waits for a result, so a failure is reported before the job fails.
  defp restore(account, document) do
    Events.imported(account, {:ok, Transfer.restore(account, document)})
    :ok
  rescue
    exception ->
      Events.imported(account, :error)
      reraise exception, __STACKTRACE__
  after
    # A failed import may have added sources too, so open lists reload either way.
    Events.changed(account)
  end
end
