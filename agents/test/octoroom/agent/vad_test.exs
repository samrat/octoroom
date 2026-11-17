defmodule Octoroom.Agent.VADTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.VAD

  defp vad(opts \\ %{}),
    do: VAD.new(Map.merge(%{frame_ms: 32, min_speech_ms: 96, min_silence_ms: 96}, opts))

  test "starts speech only after the minimum speech duration" do
    assert {[], vad} = VAD.process_all(vad(), [0.9, 0.9])
    refute vad.speaking?

    assert {[:speech_started], vad} = VAD.process(vad, 0.9)
    assert vad.speaking?
  end

  test "a short blip below min_speech_ms does not start speech" do
    assert {[], vad} = VAD.process_all(vad(), [0.9, 0.9, 0.1, 0.9, 0.9, 0.1])
    refute vad.speaking?
  end

  test "stops speech only after the minimum silence duration" do
    {[:speech_started], vad} = VAD.process_all(vad(), [0.9, 0.9, 0.9])

    assert {[], vad} = VAD.process_all(vad, [0.1, 0.1, 0.9, 0.1, 0.1])
    assert vad.speaking?

    assert {[:speech_stopped], vad} = VAD.process(vad, 0.1)
    refute vad.speaking?
  end

  test "probabilities between thresholds hold the current state" do
    {[:speech_started], speaking} = VAD.process_all(vad(), [0.9, 0.9, 0.9])
    assert {[], %{speaking?: true}} = VAD.process_all(speaking, List.duplicate(0.4, 10))

    assert {[], %{speaking?: false}} = VAD.process_all(vad(), List.duplicate(0.4, 10))
  end

  test "emits a full utterance in order" do
    probabilities = [0.0, 0.9, 0.9, 0.9, 0.95, 0.2, 0.2, 0.2, 0.0]
    assert {[:speech_started, :speech_stopped], _vad} = VAD.process_all(vad(), probabilities)
  end
end
