defmodule TeleprompterTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness
  alias Teleprompter.{Agent, RollingWindow, Store, Tracker}

  defp latest_state(harness) do
    harness
    |> Harness.notifications()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {:tracker_state, snap} -> snap
      _ -> nil
    end)
  end

  defp turn(harness, text, probs) do
    answers = Map.new(probs, fn {id, p} -> {id, %{"probability" => p}} end)
    decision = %{answers: answers, latency_ms: 48}

    Harness.push(harness, %Frames.Transcription{
      text: text,
      annotation: text,
      turn_id: 1,
      decision: decision
    })
  end

  test "checks off points in any order and prunes covered questions via UpdateStage" do
    points = ["Explain Octoroom", "Show Cloudflare SFU", "Kill the server"]

    harness =
      processor(:tracker, Tracker, points: points, threshold: 0.72)
      |> Harness.start!()
      |> Harness.push(%Frames.Start{})

    # Initial UpdateStage asks about all 3 points
    assert [%Frames.UpdateStage{stage: :decisions, opts: opts}] = Harness.upstream(harness)
    assert Enum.sort(Map.keys(opts[:questions])) == ["p1", "p2", "p3"]

    # Speaker jumps straight to point 3 first, partially touches point 1
    harness =
      turn(harness, "Let's kill the Phoenix server mid-call", %{
        "p1" => 0.42,
        "p2" => 0.08,
        "p3" => 0.94
      })

    snap = latest_state(harness)

    by_id = Map.new(snap.points, &{&1.id, &1})
    assert by_id["p3"].covered? == true
    assert by_id["p3"].quote == "Let's kill the Phoenix server mid-call"
    assert by_id["p1"].covered? == false
    assert by_id["p1"].best_probability == 0.42

    # Upstream UpdateStage now asks ONLY about p1 and p2
    %Frames.UpdateStage{opts: opts2} = List.last(Harness.upstream(harness))
    assert Enum.sort(Map.keys(opts2[:questions])) == ["p1", "p2"]

    # Covering the remaining two drops questions to %{} (zero further API calls)
    harness =
      turn(harness, "Octoroom runs on Cloudflare Realtime SFU", %{"p1" => 0.88, "p2" => 0.91})

    snap = latest_state(harness)
    assert Enum.all?(snap.points, & &1.covered?)

    %Frames.UpdateStage{opts: opts3} = List.last(Harness.upstream(harness))
    assert opts3[:questions] == %{}
  end

  test "supports live add, toggle, remove, reset, and threshold updates" do
    harness =
      processor(:tracker, Tracker, points: ["First point", "Second point"], threshold: 0.75)
      |> Harness.start!()
      |> Harness.push(%Frames.Start{})
      |> Harness.info(:tracker, {:teleprompter, {:add, "Third point"}})
      |> Harness.info(:tracker, {:teleprompter, {:toggle, "p1"}})

    snap = latest_state(harness)
    assert length(snap.points) == 3
    assert Enum.find(snap.points, &(&1.id == "p1")).covered? == true
    assert Enum.find(snap.points, &(&1.id == "p1")).manual? == true

    harness =
      harness
      |> Harness.info(:tracker, {:teleprompter, {:remove, "p2"}})
      |> Harness.info(:tracker, {:teleprompter, {:set_threshold, 0.8}})
      |> Harness.info(:tracker, {:teleprompter, :reset})

    snap = latest_state(harness)
    assert Enum.map(snap.points, & &1.text) == ["First point", "Third point"]
    assert Enum.all?(snap.points, &(not &1.covered?))
    assert snap.threshold == 0.8
  end

  test "RollingWindow maintains a sliding context window and preserves raw utterance in annotation" do
    harness =
      processor(:window, RollingWindow, window: 2)
      |> Harness.start!()
      |> Harness.push(%Frames.Transcription{text: "First sentence."})
      |> Harness.push(%Frames.Transcription{text: "Second sentence."})
      |> Harness.push(%Frames.Transcription{text: "Third sentence."})

    [t1, t2, t3] = Harness.outputs(harness, Frames.Transcription)
    assert t1.turn_id == {:typed, 1}
    assert t1.text == "First sentence."
    assert t1.annotation == "First sentence."

    assert t2.text == "First sentence.\nSecond sentence."
    assert t2.annotation == "Second sentence."

    assert t3.text == "Second sentence.\nThird sentence."
    assert t3.annotation == "Third sentence."
  end

  test "parse_lines strips bullets, numbers, checkboxes, and blank lines" do
    raw = """
    - Intro and agenda
    * [ ] Walk through the demo

    1. Show pricing
    2) Share launch timeline
    • Ask for questions
      Plain line
    """

    assert Tracker.parse_lines(raw) == [
             "Intro and agenda",
             "Walk through the demo",
             "Show pricing",
             "Share launch timeline",
             "Ask for questions",
             "Plain line"
           ]
  end

  test "Agent pipeline loads custom points saved in Store for its room_id" do
    room = "custom-room-#{System.unique_integer([:positive])}"
    custom = ["Introduce myself", "Demo live reload"]
    Store.put(room, custom, 0.85)
    on_exit(fn -> Store.delete(room) end)

    {_front, back} = Agent.pipeline(%{room_id: room, args: %{}})
    assert {:ok, _} = validate(back)

    harness =
      back
      |> Harness.start!()
      |> Harness.push(%Frames.Start{})

    snap = latest_state(harness)
    assert Enum.map(snap.points, & &1.text) == custom
    assert snap.threshold == 0.85
  end

  test "Agent pipeline validates cleanly" do
    {front, back} = Agent.pipeline(%{args: %{}})
    assert {:ok, _} = validate(front)
    assert {:ok, _} = validate(back)
  end
end
