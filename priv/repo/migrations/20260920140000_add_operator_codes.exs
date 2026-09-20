# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.Repo.Migrations.AddOperatorCodes do
  use Ecto.Migration

  @moduledoc """
  Ithibati's schema version 3, which adds the table its operator code is kept in.

  Applied whether or not the first-account claim is protected: the library asks for the table
  either way, and a schema that lags the library is a doctor that fails.

  Accounts, passkeys and sessions are preserved. The earlier migrations stay pinned to the
  versions they were written against, so replaying this history gives the same schema.
  """

  def up, do: Ithibati.Migration.up(from: 2, version: 3)
  def down, do: Ithibati.Migration.down(from: 2, version: 3)
end
