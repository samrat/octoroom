defmodule Vision.GeminiAssistant do
  @moduledoc """
  Speech-to-speech vision agent on Gemini Live: streams audio and ~1 fps
  camera/screen snapshots directly to Gemini Live.
  """
  use Octoroom.Agent

  alias Octoroom.Agent.Pipeline.Spec

  @impl true
  def instructions(_ctx) do
    """
    You are a friendly voice assistant who can also see the user's camera or shared screen
    when they turn it on. Answer concisely in a sentence or two, as spoken audio.
    """
  end

  @impl true
  def initial_prompt(_ctx),
    do: "Greet me briefly and let me know you can see my camera or screen once I share it."

  @impl true
  def pipeline(_ctx) do
    Spec.gemini_live(model: "gemini-3.8-live", voice: "Puck")
  end
end
