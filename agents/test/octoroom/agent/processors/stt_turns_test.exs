defmodule Octoroom.Agent.Processors.STTTurnsTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness
  alias Octoroom.Agent.Processors.STTTurns

  defp starts(harness), do: length(Harness.outputs(harness, Frames.UserStartedSpeaking))

  test "a sound that never became a transcript doesn't block the next barge-in" do
    harness =
      processor(:turns, STTTurns, interrupt: false)
      |> Harness.start!()
      # A breath: the VAD hears speech, no transcript follows.
      |> Harness.push([%Frames.VADUserStartedSpeaking{}, %Frames.VADUserStoppedSpeaking{}])

    assert starts(harness) == 1

    # Then the person really talks over the agent.
    harness = Harness.push(harness, %Frames.VADUserStartedSpeaking{})
    assert starts(harness) == 2
  end

  test "one stretch of speech barges in once" do
    harness =
      processor(:turns, STTTurns)
      |> Harness.start!()
      |> Harness.push(%Frames.VADUserStartedSpeaking{})
      |> Harness.push(%Frames.VADUserStartedSpeaking{})

    assert starts(harness) == 1
  end

  test "speech the VAD missed barges in on its transcript" do
    harness =
      processor(:turns, STTTurns, interrupt: false)
      |> Harness.start!()
      |> Harness.push(%Frames.InterimTranscription{text: "stop"})
      |> Harness.push(%Frames.InterimTranscription{text: "stop talking"})

    assert starts(harness) == 1
  end
end
