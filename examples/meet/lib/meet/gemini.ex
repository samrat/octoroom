defmodule Meet.Gemini do
  @moduledoc """
  A third assistant: Gemini Live, one speech-to-speech model instead of
  speech-to-text, an LLM and text-to-speech. It hears everyone mixed into
  one stream and decides for itself when to answer, so the decision model
  doesn't gate it (`Meet.Room` gives it `gate: nil`).

  Gemini 3.8 Live always has proactive audio on: it can choose not to
  answer what isn't for it, which matters with two other assistants in the
  call. Its instructions tell it to answer only when it's addressed.
  """
  use Octoroom.Agent

  @impl true
  def instructions(_ctx) do
    """
    You are Gemini, one of four AI assistants in a group video call. The others are
    Assistant, a general assistant, Atlas, who answers questions about capital cities, and
    OpenAI, another voice assistant. You hear everyone in the call mixed together. People
    mostly talk to each other and to the other assistants: answer only when someone says
    your name, Gemini, or is clearly still talking to you after you answered. Otherwise
    stay silent. Your replies are spoken aloud: a sentence or two.
    """
  end

  @impl true
  def pipeline(_ctx),
    do: Octoroom.Agent.Pipeline.Spec.gemini_live(model: "gemini-3.8-live", voice: "Puck")
end
