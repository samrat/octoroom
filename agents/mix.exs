defmodule OctoroomAgents.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/samrat/octoroom"

  def project do
    [
      app: :octoroom_agents,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description:
        "Voice and vision AI participants for Octoroom rooms (cascaded pipelines, local ONNX, Gemini Live, OpenAI Live).",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [quality: :test, q: :test]]
  end

  # Octoroom's own fakes (FakeCloudflare, FakePeerMedia) run rooms in tests.
  defp elixirc_paths(:test), do: ["lib", "test/support", Path.expand("../test/support", __DIR__)]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --only warning,consistency",
        "cmd mix test"
      ],
      q: ["quality"]
    ]
  end

  defp deps do
    [
      octoroom_dep(),
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.0"},
      {:telemetry, "~> 1.2"},
      {:req, "~> 0.5"},
      {:req_llm, "~> 1.31"},
      {:websockex, "~> 0.5.1"},
      # Silero VAD and Smart Turn run on ONNX Runtime via precompiled NIFs.
      {:onnxruntime, "~> 0.1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp octoroom_dep do
    if System.get_env("OCTOROOM_LOCAL") == "1" do
      {:octoroom, path: ".."}
    else
      {:octoroom, "~> #{@version}"}
    end
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      files: ~w(lib priv mix.exs README.md LICENSE),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      source_url_pattern: "#{@source_url}/blob/v#{@version}/agents/%{path}#L%{line}",
      extras: ["README.md"]
    ]
  end
end
