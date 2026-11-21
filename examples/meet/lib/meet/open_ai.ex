defmodule Meet.OpenAI do
  @moduledoc """
  A fourth assistant: OpenAI Live (`gpt-live-1.1`), a full-duplex
  speech-to-speech model instead of speech-to-text, an LLM and text-to-speech.
  It hears everyone mixed into one stream and decides for itself when to
  answer, so the decision model doesn't gate it (`Meet.Room` gives it
  `gate: nil`).

  Its instructions tell it to answer only when it's addressed, which matters
  with three other assistants in the call.
  """
  use Octoroom.Agent

  @impl true
  def instructions(_ctx) do
    """
    You are OpenAI, one of four AI assistants in a group video call. The others are
    Assistant, a general assistant, Atlas, who answers questions about capital cities, and
    Gemini, another voice assistant. You hear everyone in the call mixed together. People
    mostly talk to each other and to the other assistants: answer only when someone says
    your name, OpenAI, or is clearly still talking to you after you answered. Otherwise
    stay silent. Your replies are spoken aloud: a sentence or two.
    """
  end

  @impl true
  def pipeline(_ctx) do
    Octoroom.Agent.Pipeline.Spec.openai_live(
      model: "gpt-live-1.1",
      voice: "marin",
      idle_timeout_s: 15,
      wake_policy: :speech
    )
  end
end
