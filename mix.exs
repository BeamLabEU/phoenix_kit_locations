defmodule PhoenixKitLocations.MixProject do
  use Mix.Project

  @version "0.6.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_locations"

  def project do
    [
      app: :phoenix_kit_locations,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Locations module for PhoenixKit — manage physical locations with custom types.",
      package: package(),
      dialyzer: [plt_add_apps: [:phoenix_kit]],
      name: "PhoenixKitLocations",
      source_url: @source_url,
      docs: docs(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ],
      # Schema is applied by `test_helper.exs` on every `mix test` run
      # via `PhoenixKit.Migration.ensure_current/2` plus this module's
      # `Migrations.up_statements/1` — no `ecto.migrate` step here.
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitLocations.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitLocations.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset or blank => the published pin,
  # so mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var, "") |> String.trim() do
      "" when opts == [] -> {app, requirement}
      "" -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp deps do
    [
      # The floor is 2.41.1: `status_badge`'s `label` attr first shipped there.
      # The module also runs on core's shared toolkits (2.38.0) —
      # `PhoenixKitWeb.Actor`, `PhoenixKit.Activity.log/3`,
      # `Storage.ResourceFolders`, the reorganizer's `ResourceSource`,
      # `PhoenixKitWeb.Attachments`, `Utils.TreeQuery`, `Utils.Format`,
      # `mount_multilang(open_on:)` and the `:phoenix_kit_js_sources`
      # compiler — all first shipped there, none feature-detected, so a lower
      # core fails to compile. (2.0.0's V135 baseline, which V1 adopts, is
      # long subsumed.) Patch-precise floor in the compound form, so the
      # ceiling stays open through every later 2.x minor (see
      # test/core_pin_conformance_test.exs).
      pk_dep(:phoenix_kit, ">= 2.41.1 and < 3.0.0"),
      {:phoenix_live_view, "~> 1.1"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitLocations",
      # Tags in this repo are bare version numbers, not v-prefixed — a "v" ref
      # points at a tag that does not exist and 404s every HexDocs source link.
      source_ref: @version
    ]
  end
end
