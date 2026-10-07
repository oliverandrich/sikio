# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ApplicationTest do
  @moduledoc false
  # Not async: it changes application env, which other tests read.
  use ExUnit.Case, async: false

  alias Sikio.TestConfig

  # `Ecto.Migrator` starts after the repo and before Oban, whose tables it may create.
  # `migrate_on_start` controls its `:skip` option.
  test "the migrator starts before the queue and runs only when asked" do
    ids = Enum.map(Sikio.Application.children(), &Supervisor.child_spec(&1, []).id)

    assert Enum.find_index(ids, &(&1 == Sikio.Repo.repo())) <
             Enum.find_index(ids, &(&1 == Ecto.Migrator))

    assert Enum.find_index(ids, &(&1 == Ecto.Migrator)) < Enum.find_index(ids, &(&1 == Oban))

    assert skipped?() == true
    TestConfig.put_env(:sikio, :migrate_on_start, true)
    assert skipped?() == false
  end

  defp skipped? do
    {Ecto.Migrator, options} =
      Enum.find(Sikio.Application.children(), &match?({Ecto.Migrator, _}, &1))

    options[:skip]
  end
end
