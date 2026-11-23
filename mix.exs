defmodule Octoroom.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/samrat/octoroom"

  def project do
    [
      app: :octoroom,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description:
        "Programmable voice, video, and AI agent rooms for Phoenix, backed by Cloudflare Realtime SFU.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Octoroom.Application, []}
    ]
  end

  def cli do
    [preferred_envs: [quality: :test, q: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The browser client's tests run on Node's own test runner: no npm.
  defp aliases do
    [
      "test.js": ["cmd node --test test/js/*.test.mjs"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --only warning,consistency",
        "cmd mix test",
        "test.js"
      ],
      q: ["quality"]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.2"},
      {:ex_webrtc, "~> 0.17"},
      # Only its Opus NIFs (Membrane.Opus.{Encoder,Decoder}.Native), which
      # ship with a precompiled libopus.
      {:membrane_opus_plugin, "~> 0.20"},
      {:phoenix, "~> 1.7", optional: true},
      {:stream_data, "~> 1.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      files: ~w(lib priv/static mix.exs README.md LICENSE),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end
