# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.InstanceSettingsMigrationTest do
  @moduledoc """
  Tests the migration that adds the instance settings: an empty table whose defaults turn every
  platform on, gone again on rollback.
  """
  use Sikio.MigrationCase

  @before 20_261_018_110_000
  @version 20_261_018_120_000

  # An empty table means every platform is on, and leaves a conversion's target empty.
  test "the table starts empty with every platform on by default", %{repo: repo} do
    migrate(repo, :up, @version)
    assert Repo.all(from s in "instance_settings", select: s.id) == []

    Repo.insert_all("instance_settings", [%{id: 1}])

    assert Repo.all(
             from s in "instance_settings",
               select:
                 {s.podcast == true, s.youtube == true, s.peertube == true, s.mediathek == true}
           ) == [{true, true, true, true}]

    migrate(repo, :down, @before)
    assert_raise database_error(), fn -> Repo.all(from s in "instance_settings", select: s.id) end
  end
end
