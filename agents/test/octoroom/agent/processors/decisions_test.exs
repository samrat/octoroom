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

  describe "judging transcripts" do
    test "evaluates the final transcript and holds it until the answers come" do
      test = self()

      harness =
        start(
          fn text ->
            send(test, {:evaluated, text})
            {:ok, @answers}
          end,
          input: :transcript
        )
        |> Harness.push([%Frames.VADUserStartedSpeaking{}, audio(1_000)])
        |> Harness.push(%Frames.VADUserStoppedSpeaking{})

      # Nothing to judge until the transcript is final.
      assert Harness.pending_tasks(harness) == []

      harness =
        harness
        |> Harness.push(%Frames.UserStoppedSpeaking{turn_id: 1})
        |> Harness.push(%Frames.Transcription{text: " What time is it? ", turn_id: 1})

      assert Harness.outputs(harness, Frames.Transcription) == []

      harness = Harness.run_tasks(harness)
      assert_received {:evaluated, "What time is it?"}

      assert [%Frames.Transcription{decision: decision}] =
               Harness.outputs(harness, Frames.Transcription)

      assert %{addressee: "assistant", confidence: 0.81, answerable: 0.95} = decision
      refute Map.has_key?(decision, :audio_ms)
    end

    test "is the default for a model other than Google's" do
      harness =
        start(fn text -> {:ok, Map.put(@answers, "text", text)} end,
          model: "openrouter:cloudflare/clef-flash"
        )
        |> Harness.push(%Frames.Transcription{text: "Hi", turn_id: 1})
        |> Harness.run_tasks()

      assert [%Frames.Transcription{decision: %{answers: %{"text" => "Hi"}}}] =
               Harness.outputs(harness, Frames.Transcription)
    end

    test "a slow call lets the transcript go without a decision" do
      harness =
        start(fn _text -> {:ok, @answers} end, input: :transcript, max_wait_ms: 50)
        |> Harness.push(%Frames.Transcription{text: "Hi", turn_id: 1})
        |> Harness.fire_timer(:decisions, {:wait, 1})

      assert [%Frames.Transcription{decision: nil}] =
               Harness.outputs(harness, Frames.Transcription)
    end

    test "a turn with no text goes on without a decision" do
      harness =
        start(fn _text -> {:ok, @answers} end, input: :transcript)
        |> Harness.push(%Frames.UserAudio{turn_id: 1, audio: :binary.copy(<<1, 0>>, 16_000)})
        |> Harness.push(%Frames.Transcription{text: "  ", turn_id: 2})

      assert Harness.pending_tasks(harness) == []
      assert [%Frames.UserAudio{decision: nil}] = Harness.outputs(harness, Frames.UserAudio)

      assert [%Frames.Transcription{decision: nil}] =
               Harness.outputs(harness, Frames.Transcription)
    end
  end

  describe "changing the questions" do
    test "each decision carries the questions_id of the questions it answered" do
      harness =
        start(fn _text -> {:ok, @answers} end, input: :transcript, questions_id: "greet")
        |> Harness.push(%Frames.Transcription{text: "Hello?", turn_id: 1})

      # The update arrives while turn 1 is being judged: it keeps the old id.
      day = %{
        "day" => %{type: :choice, instructions: "Which day?", criteria: %{"monday" => "Monday."}}
      }

      update = %Frames.UpdateStage{stage: :decisions, opts: [questions: day, questions_id: "day"]}
      harness = Harness.push(harness, update, :upstream)
      harness = Harness.push(harness, %Frames.Transcription{text: "Tuesday", turn_id: 2})
      harness = Harness.run_tasks(harness)

      assert [%{decision: %{questions_id: "greet"}}, %{decision: %{questions_id: "day"}}] =
               Harness.outputs(harness, Frames.Transcription)

      assert Harness.errors(harness) == []
    end

    test "with no questions, turns go on at once without a call" do
      test = self()

      harness =
        start(fn _text -> send(test, :evaluated) && {:ok, @answers} end, input: :transcript)
        |> Harness.push(%Frames.UpdateStage{stage: :decisions, opts: [questions: %{}]}, :upstream)
        |> Harness.push(%Frames.Transcription{text: "Thanks, bye!", turn_id: 1})

      assert [%Frames.Transcription{decision: nil}] =
               Harness.outputs(harness, Frames.Transcription)

      assert harness.tasks == []
      refute_received :evaluated
    end

    test "other options can't change" do
      harness =
        start(fn _text -> {:ok, @answers} end, input: :transcript)
        |> Harness.push(%Frames.UpdateStage{stage: :decisions, opts: [model: "x"]}, :upstream)

      assert Harness.errors(harness) == [{{:not_updatable, [:model]}, false}]
    end
  end
end
