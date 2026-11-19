defmodule Hello.Assistant do
  @moduledoc """
  The agent: a system prompt, a greeting, and its providers. Soniox hears
  you, Nemotron (through OpenRouter) answers, and AssemblyAI speaks. These
  were the quickest to a first word of the combinations `examples/meet` tried.
  """
  use Octoroom.Agent

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
  def backend(_ctx), do: %{stt: "soniox", llm: %{provider: :openrouter}, tts: "assembly_ai"}
end
