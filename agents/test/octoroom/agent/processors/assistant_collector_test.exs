defmodule Octoroom.Agent.Processors.AssistantCollectorTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness
  alias Octoroom.Agent.Processors.AssistantCollector

  # `ms` of 24 kHz mono audio.
  defp audio(ms), do: %Frames.OutputAudio{audio: :binary.copy(<<0, 0>>, 24 * ms)}

  defp start(opts \\ []) do
    processor(:collector, AssistantCollector, [clock: fn -> 0 end] ++ opts)
    |> Harness.start!()
  end

  # A reply of two chunks: 1 s and 2 s of audio.
  defp reply(harness) do
    Harness.push(harness, [
      %Frames.LLMResponseStart{},
      %Frames.LLMText{text: "Sure, I'll add Acme. Which column should the deal size go in?"},
      %Frames.TTSText{text: "Sure, I'll add Acme."},
      audio(500),
      audio(500),
      %Frames.TTSText{text: "Which column should the deal size go in?"},
      audio(2_000)
    ])
  end

  defp messages(harness),
    do: harness |> Harness.upstream() |> Enum.filter(&match?(%Frames.AssistantMessage{}, &1))

  describe "spoken/2" do
    @chunks [{"One two three four.", 1_000}, {"Five six seven eight.", 1_000}]

    test "whole chunks, then the share of the next chunk's words" do
      assert AssistantCollector.spoken(@chunks, 0) == ""
      assert AssistantCollector.spoken(@chunks, 1_000) == "One two three four."
      assert AssistantCollector.spoken(@chunks, 1_500) == "One two three four. Five six"
      # Rounded down: a word not fully played wasn't heard.
      assert AssistantCollector.spoken(@chunks, 1_700) == "One two three four. Five six"

      assert AssistantCollector.spoken(@chunks, 5_000) ==
               "One two three four. Five six seven eight."
    end

    test "chunks without audio weren't heard" do
      assert AssistantCollector.spoken([{"Failed.", 0}, {"Spoken.", 500}], 500) == "Spoken."
    end
  end

  test "a reply that plays to the end goes upstream when its audio is done" do
    harness = start() |> reply() |> Harness.push(%Frames.LLMResponseEnd{})

    assert messages(harness) == []
    assert Harness.timer_pending?(harness, :collector, :played)

    harness = Harness.fire_timer(harness, :collector, :played)

    assert [%Frames.AssistantMessage{interrupted?: false, text: text}] = messages(harness)
    assert text == "Sure, I'll add Acme. Which column should the deal size go in?"
  end

  test "an interruption keeps what played, by the runner's flush report" do
    harness = start() |> reply() |> Harness.push(%Frames.Interruption{})

    # Waiting for the report.
    assert messages(harness) == []

    # 3 s queued, 1 s dropped: 2 s heard, halfway through chunk two.
    harness = Harness.push(harness, %Frames.AudioFlushed{dropped_ms: 1_000})

    assert [%Frames.AssistantMessage{interrupted?: true, text: text}] = messages(harness)
    assert text == "Sure, I'll add Acme. Which column should the"
    refute Harness.timer_pending?(harness, :collector, :flush_timeout)
  end

  test "it cuts a finished reply whose audio is still playing" do
    harness =
      start()
      |> reply()
      |> Harness.push([%Frames.LLMResponseEnd{}, %Frames.Interruption{}])
      |> Harness.push(%Frames.AudioFlushed{dropped_ms: 2_000})

    assert [%Frames.AssistantMessage{interrupted?: true, text: "Sure, I'll add Acme."}] =
             messages(harness)

    refute Harness.timer_pending?(harness, :collector, :played)
  end

  test "an interruption after everything played isn't a cut" do
    harness =
      start()
      |> reply()
      |> Harness.push([%Frames.LLMResponseEnd{}, %Frames.Interruption{}])
      |> Harness.push(%Frames.AudioFlushed{dropped_ms: 0})

    assert [%Frames.AssistantMessage{interrupted?: false, text: text}] = messages(harness)
    assert text =~ "deal size go in?"
  end

  test "without a flush report it assumes everything queued was heard" do
    harness =
      start()
      |> reply()
      |> Harness.push(%Frames.Interruption{})
      |> Harness.fire_timer(:collector, :flush_timeout)

    assert [%Frames.AssistantMessage{text: text}] = messages(harness)
    assert text =~ "deal size go in?"
  end

  test "an interruption before any audio: nothing was said" do
    harness =
      start()
      |> Harness.push([%Frames.LLMResponseStart{}, %Frames.LLMText{text: "Once upon"}])
      |> Harness.push(%Frames.Interruption{})

    assert [%Frames.AssistantMessage{interrupted?: true, text: ""}] = messages(harness)
  end

  test "with voice: false, the text is what was said" do
    harness =
      start(voice: false)
      |> Harness.push([%Frames.LLMResponseStart{}, %Frames.LLMText{text: "Once upon"}])
      |> Harness.push(%Frames.Interruption{})

    assert [%Frames.AssistantMessage{interrupted?: true, text: "Once upon"}] = messages(harness)
  end

  test "a new reply releases the last one, still playing, first" do
    harness =
      start()
      |> reply()
      |> Harness.push([%Frames.LLMResponseEnd{}, %Frames.LLMResponseStart{}])

    assert [%Frames.AssistantMessage{interrupted?: false}] = messages(harness)
  end
end
