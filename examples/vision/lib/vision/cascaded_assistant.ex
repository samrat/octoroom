defmodule Vision.CascadedAssistant do
  @moduledoc """
  Cascaded voice + vision agent: Soniox hears your voice, Gemini Flash answers
  using your latest camera or screen-share snapshot, and TinyVoca speaks
  locally on ONNX Runtime.
  """
  use Octoroom.Agent

  alias Octoroom.Agent.Pipeline.Spec

  @impl true
  def instructions(_ctx) do
    """
    You are a friendly voice assistant who can also see the user's camera or shared screen
    when they turn it on. Any attached images are labeled with their source (such as
    [Guest's camera] or [Guest's screen]). Describe what you actually see concisely.
    Your replies are spoken aloud: answer in a sentence or two, with no markdown, lists or emoji.
    """
  end

  @impl true
  def initial_prompt(_ctx),
    do: "Greet me briefly and let me know I can turn on my camera or share my screen."

  @impl true
  def pipeline(_ctx) do
    Spec.default(
      stt: "soniox:stt-rt-v6",
      llm: [
        provider: :google,
        model: "gemini-3.5-flash",
        reasoning_effort: :minimal
      ],
      tts: [provider: :tiny_voca, model: "tiny-voca", voice: "F2"]
    )
  end
end
