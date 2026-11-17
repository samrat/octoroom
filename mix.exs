defmodule Octoroom.MixProject do
  use Mix.Project

  def project do
    [
      app: :octoroom,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The browser client's tests run on Node's own test runner: no npm.
  defp aliases do
    ["test.js": ["cmd node --test test/js/*.test.mjs"]]
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
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
