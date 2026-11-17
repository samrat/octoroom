defmodule Octoroom.Agent.Processors.ToolsTest do
  # Scheduling of non-blocking tool results by the tools stage's state:
  # `:idle`, `:user_speaking` or `:responding`.
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness
  alias Octoroom.Agent.Processors

  defp harness, do: Harness.start!(processor(:tools, Processors.Tools), ctx: %{tools: []})

  defp result(scheduling, extra \\ %{}) do
    Map.merge(
      %{call_id: "t1", name: "track_package", response: %{eta: "today"}, scheduling: scheduling},
      extra
    )
  end

  defp deliver(harness, result),
    do: Harness.info(harness, :tools, {:octoroom_agent_async_tool_result, result})

  defp delivered(harness),
    do: for(%Frames.AsyncToolResult{result: r} <- Harness.upstream(harness), do: r)

  test "silent results go to the context at once, even mid-reply" do
    harness =
      harness()
      |> Harness.push(%Frames.LLMResponseStart{})
      |> deliver(result(:silent))

    assert [%{scheduling: :silent}] = delivered(harness)
    refute Harness.interrupted?(harness)
  end

  test "when_idle results go at once when nothing is happening" do
    assert [%{scheduling: :when_idle}] = harness() |> deliver(result(:when_idle)) |> delivered()
  end

  test "when_idle results wait while the user is speaking" do
    harness =
      harness()
      |> Harness.push(%Frames.UserStartedSpeaking{})
      |> deliver(result(:when_idle))

    assert delivered(harness) == []

    harness = Harness.push(harness, %Frames.UserStoppedSpeaking{})
    assert [%{scheduling: :when_idle}] = delivered(harness)
  end

  test "when_idle results wait for the reply, including its tool rounds" do
    harness =
      harness()
      |> Harness.push(%Frames.LLMResponseStart{})
      |> deliver(result(:when_idle))
      |> Harness.push(%Frames.LLMResponseEnd{})

    assert [%{scheduling: :when_idle}] = delivered(harness)
  end

  test "interrupt results cut off the current reply" do
    harness =
      harness()
      |> Harness.push(%Frames.LLMResponseStart{})
      |> deliver(result(:interrupt))

    assert Harness.interrupted?(harness)
    assert [%{scheduling: :interrupt}] = delivered(harness)
    assert Harness.state(harness, :tools).name == :idle
  end

  test "interrupt results wait while the user is speaking, without interrupting" do
    harness =
      harness()
      |> Harness.push(%Frames.UserStartedSpeaking{})
      |> deliver(result(:interrupt, %{event: %{type: "package_update"}}))

    assert delivered(harness) == []
    refute Harness.interrupted?(harness)

    harness = Harness.push(harness, %Frames.UserStoppedSpeaking{})
    assert [%{scheduling: :interrupt}] = delivered(harness)

    # The control event reaches the owner once.
    assert Harness.notifications(harness) == [{:control, %{type: "package_update"}}]
  end
end
