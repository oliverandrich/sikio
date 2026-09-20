# SPDX-License-Identifier: AGPL-3.0-or-later

defmodule Sikio.MixProject do
  use Mix.Project

  def project do
    [
      app: :sikio,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Sikio.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  # Read by license tooling and by people; Sikio is an application, so Hex never sees it.
  defp package, do: [licenses: ["AGPL-3.0-or-later"]]

  defp deps do
    [
      {:wallaby, "~> 0.31.0", only: :test, runtime: false},
      {:ithibati, "== 0.4.0"},
      {:oban, "~> 2.24"},
      # The transport is Mint. Req stays out of the release: it is here for `Req.Test`, which
      # is what every feed stub is, and for Igniter, which wants it in development.
      {:mint, "~> 1.10"},
      {:req, "~> 0.7.4", only: [:dev, :test]},
      {:floki, "~> 0.38.4"},
      {:html_sanitize_ex, "~> 1.4"},
      {:saxy, "~> 1.6"},
      {:tidewave, "~> 0.9.0", only: :dev},
      {:mix_audit, "~> 2.1.5", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.15.0", only: [:dev, :test], runtime: false},
      {:excellent_migrations, "~> 0.1.10", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.5.0", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:lucide_icons, "~> 2.4.0"},
      {:ithibati_starter,
       [
         only: :dev,
         github: "oliverandrich/ithibati-starter",
         ref: "main",
         override: true,
         runtime: false
       ]},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind sikio", "esbuild sikio"],
      "assets.deploy": [
        "tailwind sikio --minify",
        "esbuild sikio --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "format --check-formatted",
        "credo --strict",
        "xref graph --label compile-connected --fail-above 0",
        # --skip honours the `sobelow_skip` attributes in the source. Each one names a single call
        # and carries the reason above it, so an accepted false positive is reviewable in the diff
        # rather than invisible in a configuration file.
        "sobelow --exit --skip",
        "ecto.create --quiet",
        "ecto.migrate --quiet",
        "ithibati.doctor",
        "assets.build",
        "test"
      ]
    ]
  end
end
