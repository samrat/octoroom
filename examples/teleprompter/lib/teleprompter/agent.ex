defmodule Teleprompter.Agent do
  @moduledoc """
  Silent talking-points listener with no LLM and no TTS (`voice: false`).

  Pipeline:

      front (per speaker): vad -> stt (AssemblyAI) -> turns
      back:                window -> decisions (Clef Flash) -> tracker
  """
  use Octoroom.Agent

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Processors
  alias Teleprompter.{RollingWindow, Store, Tracker}

  @presets [
    %{
      id: "octoroom_demo",
      name: "Octoroom Deploy Demo",
      points: [
        "Explain what Octoroom is (Elixir library for voice AI agents and conversation orchestration)",
        "Show both browser and native iOS clients connected via Cloudflare Realtime SFU",
        "Kill or restart the Phoenix server right in the middle of the call",
        "Point out that audio and video keep flowing with zero drops while the server is down",
        "Show sessions resuming automatically and workers picking back up with persisted state"
      ]
    },
    %{
      id: "product_pitch",
      name: "Product Pitch (5 points)",
      points: [
        "State the core pain point customers struggle with today",
        "Introduce the product and what makes the approach different",
        "Walk through a concrete example or live demo",
        "Share early traction, benchmarks, or pricing",
        "Close with a clear call to action or URL"
      ]
    },
    %{
      id: "sales_bant",
      name: "Sales Discovery (BANT)",
      points: [
        "Understand their current workflow and main bottleneck (Need)",
        "Clarify who signs off or owns the decision (Authority)",
        "Discuss budget range or current spend on alternatives (Budget)",
        "Establish target launch date or urgency (Timeline)",
        "Agree on concrete next steps and follow-up date"
      ]
    }
  ]

  def presets, do: @presets

  def default_points, do: hd(@presets).points

  def preset_points(id) do
    case Enum.find(@presets, &(&1.id == id)) do
      %{points: points} -> points
      nil -> default_points()
    end
  end

  @impl true
  def pipeline(ctx) do
    stored = Store.get(Map.get(ctx, :room_id)) || %{}
    points = Map.get(ctx.args, :points) || Map.get(stored, :points) || default_points()
    threshold = Map.get(ctx.args, :threshold) || Map.get(stored, :threshold) || 0.72
    initial_points = Tracker.build_points(points)

    front =
      processor(:vad, Processors.VAD, min_silence_ms: 250)
      |> processor(:stt, Processors.STT,
        provider: :assembly_ai,
        model: "assemblyai-stt-3-7-realtime-agent",
        region: :eu,
        min_end_of_turn_silence_when_confident: 220
      )
      |> processor(:turns, Processors.STTTurns, interrupt: false)

    back =
      processor(:window, RollingWindow, window: 3)
      |> processor(:decisions, Processors.Decisions,
        model: "openrouter:cloudflare/clef-flash",
        questions: Tracker.questions_for(initial_points),
        questions_id: 1
      )
      |> processor(:tracker, Tracker, points: points, threshold: threshold)

    {front, back}
  end
end
