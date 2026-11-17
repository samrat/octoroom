defmodule Octoroom.Agent.Processors.DecisionsTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness
  alias Octoroom.Agent.Processors.Decisions

  @answers %{
    "addressee" => %{
      "choice" => "assistant",
      "confidence" => 0.812,
      "probabilities" => %{"assistant" => 0.812, "person" => 0.05}
    },
    "answerable" => %{"probability" => 0.947}
  }

  defp start(evaluate, opts \\ []) do
    processor(:decisions, Decisions, [evaluate: evaluate] ++ opts)
    |> Harness.start!(async: :manual)
  end

  defp audio(ms), do: %Frames.InputAudio{audio: :binary.copy(<<1, 0>>, div(16_000 * ms, 1_000))}

  test "evaluates from the VAD's stop and holds the transcript until the answers come" do
    test = self()

    harness =
      start(fn wav ->
        send(test, {:evaluated, byte_size(wav)})
        {:ok, @answers}
      end)
      |> Harness.push([audio(200), %Frames.VADUserStartedSpeaking{}, audio(1_000)])
      |> Harness.push(%Frames.VADUserStoppedSpeaking{})
      |> Harness.push(%Frames.UserStoppedSpeaking{turn_id: 1})
      |> Harness.push(%Frames.Transcription{text: "What time is it?", turn_id: 1})

    # Held: the evaluation hasn't finished.
    assert Harness.outputs(harness, Frames.Transcription) == []

    harness = Harness.run_tasks(harness)
    assert_received {:evaluated, bytes}
    # 200 ms of preroll + 1 s of speech, plus a 44-byte WAV header.
    assert bytes == div(16_000 * 2 * 6, 5) + 44

    assert [%Frames.Transcription{decision: decision}] =
             Harness.outputs(harness, Frames.Transcription)

    assert %{addressee: "assistant", confidence: 0.81, answerable: 0.95} = decision
    assert decision.probabilities["assistant"] == 0.81
  end

  test "a half-cascaded turn is evaluated from its own audio" do
    harness =
      start(fn _wav -> {:ok, @answers} end)
      |> Harness.push(%Frames.UserAudio{turn_id: 1, audio: :binary.copy(<<1, 0>>, 16_000)})

    assert Harness.outputs(harness, Frames.UserAudio) == []
    harness = Harness.run_tasks(harness)

    assert [%Frames.UserAudio{decision: %{addressee: "assistant"}}] =
             Harness.outputs(harness, Frames.UserAudio)
  end

  test "a slow call lets the transcript go without a decision" do
    harness =
      start(fn _wav -> {:ok, @answers} end, max_wait_ms: 50)
      |> Harness.push([%Frames.VADUserStartedSpeaking{}, audio(1_000)])
      |> Harness.push(%Frames.VADUserStoppedSpeaking{})
      |> Harness.push(%Frames.UserStoppedSpeaking{turn_id: 1})
      |> Harness.push(%Frames.Transcription{text: "Hi", turn_id: 1})

    harness = Harness.fire_timer(harness, :decisions, {:wait, 1})
    assert [%Frames.Transcription{decision: nil}] = Harness.outputs(harness, Frames.Transcription)
  end

  test "talking again after a pause cancels the call" do
    harness =
      start(fn _wav -> {:ok, @answers} end)
      |> Harness.push([%Frames.VADUserStartedSpeaking{}, audio(1_000)])
      |> Harness.push(%Frames.VADUserStoppedSpeaking{})

    assert [{:decisions, {:evaluate, _}}] = Harness.pending_tasks(harness)
    harness = Harness.push(harness, %Frames.VADUserStartedSpeaking{})
    assert Harness.pending_tasks(harness) == []
  end
end
