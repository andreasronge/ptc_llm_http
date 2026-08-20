defmodule PtcLlmHttp.MixProject do
  use Mix.Project

  @app :ptc_llm_http
  @version "0.0.1"
  @source_url "https://github.com/andreasronge/ptc_llm_http"

  def project do
    [
      app: @app,
      version: @version,
      # The consumer surface, not the development surface: this library's only
      # runtime dependency is Jason, and `scripts/ci/minimum-elixir.sh` compiles
      # it under this version with nothing else fetched. The lint and property
      # tooling needs a newer Elixir, so the suite itself runs one tier above
      # (see the `compat` job). The minimum OTP release is not declared yet --
      # Slice 1's socket/TLS spike establishes it from required `:socket` and
      # `:ssl` behavior instead of guessing.
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      releases: releases(),
      usage_rules: usage_rules(),
      name: "PtcLlmHttp",
      description:
        "Bounded BEAM-native HTTP/1 transport and wire codecs for OpenAI-compatible LLM requests.",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      test_coverage: [summary: [threshold: 0]],
      dialyzer: [
        plt_core_path: dialyzer_plt_core_path(),
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:ex_unit, :mix, :public_key, :ssl],
        ignore_warnings: ".dialyzer_ignore.exs",
        list_unused_filters: true
      ]
    ]
  end

  # The core PLT (Erlang/Elixir/OTP plus `plt_add_apps`) is identical across
  # every worktree of this repo, and the plan expects several agents to work in
  # parallel worktrees. Keeping it worktree-local would rebuild it from scratch
  # in each one. `plt_file` -- this project's own module signatures -- stays
  # worktree-local, because it legitimately differs between diverging branches
  # and concurrent writers would race.
  #
  # CI keeps the repo-local "priv/plts" path: `actions/cache` restores and
  # saves a path inside the checkout, not the user cache directory of an
  # ephemeral runner.
  defp dialyzer_plt_core_path do
    if System.get_env("CI") do
      "priv/plts"
    else
      Path.expand("~/.cache/ptc_llm_http/dialyzer_plts")
    end
  end

  def application do
    [
      mod: {PtcLlmHttp.Application, []},
      # `:ssl`/`:public_key`/`:crypto` are the transport's trust and handshake
      # sources. They are declared here so the minimal-release smoke gate
      # assembles them from the first commit, before the transport slice lands.
      extra_applications: [:crypto, :logger, :public_key, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [
        check: :test,
        full_check: :test,
        soak: :test,
        coverage: :test
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Dependency rules injected into AGENTS.md by `mix usage_rules.sync`. The
  # bulky language and runtime rules are linked rather than inlined so the
  # repository instructions stay readable.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [
        {"usage_rules:elixir", link: :markdown, main: false},
        {"usage_rules:otp", link: :markdown, main: false}
      ]
    ]
  end

  # Runtime dependencies stay minimal by contract: JSON only. Req, Finch,
  # Mint, an HTTP server, a model database, and provider SDKs are not runtime
  # dependencies of this package and must not become ones.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:usage_rules, "~> 1.2", only: :dev, runtime: false}
    ]
  end

  # The gates are repository-owned shell scripts so the Git hooks, these
  # aliases, and GitHub Actions all run one implementation. See AGENTS.md.
  defp aliases do
    [
      check: ["cmd scripts/ci/check.sh"],
      full_check: ["cmd scripts/ci/full_check.sh"],
      coverage: ["test --cover"],
      # Long-running resource/soak suite; excluded from `mix test` by default
      # (test/test_helper.exs) because its signal is a trend, not a per-commit
      # pass/fail.
      soak: ["test --only soak"]
    ]
  end

  # Exists only so `scripts/ci/release.sh` can assemble a minimal release and
  # prove application startup and TLS trust inside it. This package is a
  # library; consumers do not deploy this release.
  defp releases do
    [
      ptc_llm_http: [
        include_executables_for: [:unix]
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md", "docs/protocol-evidence.md", "LICENSE"]
    ]
  end

  defp package do
    [
      files:
        ~w(lib docs/protocol-evidence.md .formatter.exs mix.exs README.md LICENSE CHANGELOG.md),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end
end
