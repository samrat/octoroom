defmodule Octoroom.Agent.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Tool
  alias Octoroom.Agent.ToolExecutor

  defmodule Handler do
    def set_focus(%{id: id, name: name, args: args}, context) do
      send(context.test_pid, {:handler_ran_in, self()})
      focus = args["focus"]

      {%{id: id, name: name, response: %{result: "ok", focus: focus}},
       %{type: "focus_set", focus: focus}, Map.put(context, :focus, focus)}
    end
  end

  @call %{id: "call-1", name: "set_focus", args: %{"focus" => "Roadmap"}}

  test "runs handlers in the calling process" do
    context = %{test_pid: self()}

    assert {[{%{response: %{result: "ok", focus: "Roadmap"}}, %{type: "focus_set"}}],
            %{focus: "Roadmap"}} = ToolExecutor.run([@call], [tool()], context)

    assert_receive {:handler_ran_in, pid}
    assert pid == self()
  end

  describe "non-blocking calls" do
    test "Tool helpers read behavior and scheduling" do
      async_tool = %{tool() | behavior: :non_blocking, scheduling: :interrupt}

      assert Tool.non_blocking?(@call, [async_tool])
      refute Tool.non_blocking?(@call, [tool()])
      refute Tool.non_blocking?(%{name: "unknown"}, [async_tool])
      assert Tool.scheduling(@call, [async_tool]) == :interrupt
      assert Tool.scheduling(@call, [tool()]) == :when_idle
    end

    test "runs each call in a task and replies with the tool's scheduling" do
      async_tool = %{tool() | behavior: :non_blocking, scheduling: :silent}

      assert :ok =
               ToolExecutor.run_async([@call], [async_tool], %{test_pid: self()},
                 reply_to: self()
               )

      assert_receive {:handler_ran_in, handler_pid}, 1_000
      refute handler_pid == self()

      assert_receive {:octoroom_agent_async_tool_result,
                      %{
                        call_id: "call-1",
                        name: "set_focus",
                        response: %{result: "ok", focus: "Roadmap"},
                        scheduling: :silent,
                        event: %{type: "focus_set"}
                      }},
                     1_000
    end
  end

  defp tool do
    %Tool{
      name: "set_focus",
      description: "Set focus.",
      parameters: %{type: "object", properties: %{focus: %{type: "string"}}},
      handler: {Handler, :set_focus}
    }
  end
end
