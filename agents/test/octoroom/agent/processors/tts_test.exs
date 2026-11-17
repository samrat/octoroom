defmodule Octoroom.Agent.Processors.TTSTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness
  alias Octoroom.Agent.Processors

  defp start do
    synthesize = fn text, on_audio -> on_audio.("<#{text}>") && :ok end

    processor(:tts, Processors.TTS, synthesize: synthesize)
    |> Harness.start!(async: :manual)
  end

  test "chunks queued during synthesis go out as one request; the end waits" do
    harness =
      Harness.push(start(), [
        %Frames.Text{text: "One."},
        %Frames.Text{text: "Two."},
        %Frames.Text{text: "Three."},
        %Frames.LLMResponseEnd{}
      ])

    assert Harness.outputs(harness, Frames.LLMResponseEnd) == []

    harness = Harness.run_tasks(harness)

    assert [
             %Frames.TTSStarted{},
             %Frames.TTSText{text: "One."},
             %Frames.OutputAudio{audio: "<One.>"},
             %Frames.TTSText{text: "Two. Three."},
             %Frames.OutputAudio{audio: "<Two. Three.>"},
             %Frames.TTSStopped{},
             %Frames.LLMResponseEnd{}
           ] = Harness.outputs(harness)
  end

  test "an interruption drops queued text" do
    harness =
      start()
      |> Harness.push([%Frames.Text{text: "One."}, %Frames.Text{text: "Two."}])
      |> Harness.push(%Frames.Interruption{})
      |> Harness.run_tasks()

    assert Harness.outputs(harness, Frames.OutputAudio) == []
  end

  test "a failed chunk reports an error and moves on" do
    synthesize = fn
      "bad", _on_audio -> {:error, :provider_down}
      text, on_audio -> on_audio.(text) && :ok
    end

    harness =
      processor(:tts, Processors.TTS, synthesize: synthesize)
      |> Harness.run([%Frames.Text{text: "bad"}, %Frames.Text{text: "good"}])

    assert [{:provider_down, false}] = Harness.errors(harness)
    assert [%Frames.OutputAudio{audio: "good"}] = Harness.outputs(harness, Frames.OutputAudio)
  end
end
