# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.AdminMigrationTest do
  @moduledoc """
  Tests the migration that adds the administrator flag. The account that claimed the instance
  becomes its administrator; every other account stays a member.
  """
  use Sikio.MigrationCase

  @before 20_261_018_090_000
  @version 20_261_018_100_000

  # Ithibati's record of the claim, with the claiming account or none.
  defp bootstrap!(user_id) do
    now = DateTime.utc_now()
    row = %{id: Ecto.UUID.bingenerate(), user_id: user_id, claimed: true}
    Repo.insert_all("ithibati_bootstrap", [Map.merge(row, %{inserted_at: now, updated_at: now})])
  end

  test "the account that claimed the instance becomes its administrator", %{repo: repo} do
    migrate(repo, :up, @before)

    %{id: ada} = user!("ada")
    %{id: bo} = user!("bo")
    bootstrap!(ada)

    migrate(repo, :up, @version)

    assert Repo.all(from u in "users", order_by: u.username, select: {u.id, u.admin == true}) ==
             [{ada, true}, {bo, false}]

    migrate(repo, :down, @before)
    assert_raise database_error(), fn -> Repo.all(from u in "users", select: u.admin) end
  end

  # A claimed instance whose first account was deleted keeps a bootstrap row without an account.
  test "an instance whose first account is gone has no administrator", %{repo: repo} do
    migrate(repo, :up, @before)
    user!("bo")
    bootstrap!(nil)

    migrate(repo, :up, @version)

    assert Repo.all(from u in "users", select: u.admin == true) == [false]
  end
end
