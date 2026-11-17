defmodule Octoroom.Agent.Processor.StateMachineTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness

  # Waits for silence; holds async results until idle.
  defmodule Turns do
    use Octoroom.Agent.Processor.StateMachine

    @impl true
    def init(_opts, _ctx), do: {:ok, :idle, %{entered: []}}

    @impl true
    def handle_event(%Frames.VADUserStartedSpeaking{}, _state, data),
      do: {:next_state, :speaking, data}

    def handle_event(%Frames.VADUserStoppedSpeaking{}, :speaking, data),
      do: {:next_state, :paused, data, [{:state_timeout, 2_000, :silence}]}

    def handle_event({:state_timeout, :silence}, :paused, data) do
      {:next_state, :idle, data, [{:push, %Frames.UserStoppedSpeaking{turn_id: 1}, :downstream}]}
    end

    # Results wait until the user is done.
    def handle_event(%Frames.AsyncToolResult{}, state, _data) when state != :idle,
      do: {:keep_state_and_data, [:postpone]}

    def handle_event(%Frames.AsyncToolResult{} = frame, :idle, _data),
      do: {:keep_state_and_data, [{:push, %{frame | result: :delivered}, :downstream}]}

    @impl true
    def state_enter(_old, new, data), do: {:keep_state, %{data | entered: data.entered ++ [new]}}
  end

  defp start, do: processor(:turns, Turns) |> Harness.start!()

  test "a state timeout fires and moves on" do
    harness =
      Harness.push(start(), [%Frames.VADUserStartedSpeaking{}, %Frames.VADUserStoppedSpeaking{}])

    assert Harness.timer_pending?(harness, :turns, :__state_timeout__)
    harness = Harness.fire_timer(harness, :turns, :__state_timeout__)

    assert [%Frames.UserStoppedSpeaking{}] = Harness.outputs(harness, Frames.UserStoppedSpeaking)
    assert Harness.state(harness, :turns).data.entered == [:speaking, :paused, :idle]
  end

  test "a state change cancels the state timeout" do
    harness =
      Harness.push(start(), [
        %Frames.VADUserStartedSpeaking{},
        %Frames.VADUserStoppedSpeaking{},
        %Frames.VADUserStartedSpeaking{}
      ])

    refute Harness.timer_pending?(harness, :turns, :__state_timeout__)
  end

  test "postponed events are delivered after the next state change" do
    harness =
      Harness.push(start(), [
        %Frames.VADUserStartedSpeaking{},
        %Frames.AsyncToolResult{result: :pending}
      ])

    assert Harness.outputs(harness, Frames.AsyncToolResult) == []

    harness =
      harness
      |> Harness.push(%Frames.VADUserStoppedSpeaking{})
      |> Harness.fire_timer(:turns, :__state_timeout__)

    # Postponed again in :paused, delivered once :idle.
    assert [%Frames.AsyncToolResult{result: :delivered}] =
             Harness.outputs(harness, Frames.AsyncToolResult)
  end

  test "unmatched frames pass through" do
    harness = Harness.push(start(), %Frames.LLMText{text: "x"})
    assert [%Frames.LLMText{text: "x"}] = Harness.outputs(harness)
  end
end
