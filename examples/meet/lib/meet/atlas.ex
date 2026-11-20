defmodule Meet.Atlas do
  @moduledoc """
  A second assistant that only answers questions about capital cities.

  It asks the decision model one more question than the default ("is this
  about a capital city?") and its `decide/2` reads the answer: anything
  else it leaves alone, even when it's asked directly.
  """
  use Octoroom.Agent

  @impl true
  def instructions(_ctx) do
    """
    You are Atlas, one of four AI assistants in a group video call. You only answer questions
    about capital cities; Assistant, Gemini and OpenAI handle everything else. Each line from the call
    starts with the speaker's name in brackets. Your replies are spoken aloud: a sentence or
    two, no markdown, and don't start with a name tag.
    """
  end

  # Soniox hears the call: Reson8 allows one connection at a time, and
  # Assistant has it. Nemotron through OpenRouter: quicker to first text than
  # Gemini. It speaks with AssemblyAI's Titus voice, so it doesn't sound like
  # Assistant.
  @impl true
  def pipeline(_ctx) do
    Octoroom.Agent.Pipeline.Spec.default(
      stt: "soniox:stt-rt-v6",
      llm: [
        provider: :openrouter,
        model: "nvidia/nemotron-3.5-lightning",
        reasoning_effort: :none,
        provider_options: [openrouter_provider: %{sort: "latency"}]
      ],
      tts: [provider: :assembly_ai, model: "assemblyai-tts-1", voice: "aai-titus"]
    )
  end

  @impl true
  def questions(ctx) do
    Map.put(Octoroom.Agent.default_questions(ctx), "capital", %{
      type: :boolean,
      instructions: "Is this a question about the capital city of a country, state or region?"
    })
  end

  @impl true
  def decide(turn, ctx) do
    case get_in(turn.decision, [:answers, "capital", "probability"]) do
      p when is_number(p) and p >= 0.6 -> Octoroom.Agent.decide(turn, ctx)
      _ -> {:listen, :not_about_capitals}
    end
  end
end
