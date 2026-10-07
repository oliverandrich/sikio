# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.ApplicationTest do
  @moduledoc false
  # Not async: it changes the application's configuration, which every other test reads.
  use ExUnit.Case, async: false

  alias Sikio.TestConfig

  # The migrator stands after the repository it migrates and before the queue, whose tables it
  # may have to create. It runs only where the configuration asks for it.
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
