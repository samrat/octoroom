defmodule Hello.Assistant do
  @moduledoc """
  The agent: a system prompt, a greeting, and its providers. Soniox hears
  you, Nemotron (through OpenRouter) answers, and AssemblyAI speaks. These
  were the quickest to a first word of the combinations `examples/meet` tried.
  """
  use Octoroom.Agent

  alias Octoroom.Agent.Pipeline.Spec

  @impl true
  def instructions(_ctx) do
    """
    You are a friendly voice assistant. Your replies are spoken aloud: answer in a sentence
    or two, with no markdown, lists or emoji.
    """
  end

  @impl true
  def initial_text(_ctx), do: "Greet me in one short sentence."

  @impl true
  def pipeline(_ctx) do
    Spec.default(
      stt: "soniox:stt-rt-v6",
      # Reasoning is off for voice, and OpenRouter picks its quickest host.
      llm: [
        provider: :openrouter,
        model: "nvidia/nemotron-3.5-lightning",
        reasoning_effort: :none,
        provider_options: [openrouter_provider: %{sort: "latency"}]
      ],
      tts: "assembly_ai:assemblyai-tts-1"
    )
  end
end
