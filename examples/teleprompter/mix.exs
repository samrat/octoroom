defmodule Teleprompter.MixProject do
  use Mix.Project

  def project do
    [
      app: :teleprompter,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Teleprompter.Application, []}]
  end

  defp deps do
    [
      {:octoroom, path: "../..", override: true},
      {:octoroom_agents, path: "../../agents"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:decimal, "~> 3.2", override: true}
    ]
  end
end
