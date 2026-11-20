defmodule OctoroomAgents.MixProject do
  use Mix.Project

  def project do
    [
      app: :octoroom_agents,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Octoroom's own fakes (FakeCloudflare, FakePeerMedia) run rooms in tests.
  # Octoroom's own fakes (FakeCloudflare, FakePeerMedia) run rooms in tests.
  defp elixirc_paths(:test), do: ["lib", "test/support", Path.expand("../test/support", __DIR__)]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:octoroom, path: ".."},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.0"},
      {:telemetry, "~> 1.2"},
      {:req, "~> 0.5"},
      # Pinned for the Gemini Decisions API (google:gemini-decision-1), which
      # the agents' decision gate uses and released versions (1.30) lack.
      # Subvocal used this commit. Needs a release before a Hex publish.
      {:req_llm, github: "agentjido/req_llm", ref: "d711c4ab9ea75d3243643c68452825aa4cfaebe1"},
      {:websockex, "~> 0.5.1"},
      # Silero VAD and Smart Turn run on ONNX Runtime via precompiled NIFs.
      {:onnxruntime, "~> 0.1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
