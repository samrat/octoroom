defmodule Octoroom.Agent.ToolExecutor do
  @moduledoc """
  Runs tool handlers inside the agent's process, on the app's node, so a
  handler can call the app directly (its Repo, PubSub, contexts).

  Subvocal also had an `:owner` mode that sent calls to a channel process;
  agents run next to the app, so it isn't copied.
  """

  alias Octoroom.Agent.ToolDispatcher

  @type result :: {map(), map() | nil}

  @doc """
  Runs `calls` and returns `{results, context}`, the same shape as
  `Octoroom.Agent.ToolDispatcher.handle_calls/3`. `opts` is accepted for
  compatibility and ignored.
  """
  @spec run([map()], list(), map() | nil, keyword()) :: {[result()], map()}
  def run(calls, tools, context, _opts \\ []),
    do: ToolDispatcher.handle_calls(calls, tools, context || %{})

  @doc """
  Starts non-blocking `calls` and returns at once. Each handler runs in its
  own task, and its result is sent to `:reply_to` (the agent's process) as
  `{:octoroom_agent_async_tool_result, %{call_id, name, response, scheduling, event}}`.
  """
  @spec run_async([map()], list(), map() | nil, keyword()) :: :ok
  def run_async(calls, tools, context, opts) do
    reply_to = Keyword.fetch!(opts, :reply_to)
    context = context || %{}

    Enum.each(calls, fn call ->
      Task.start(fn ->
        {[{response, event}], _context} = ToolDispatcher.handle_calls([call], tools, context)
        scheduling = Octoroom.Agent.Tool.scheduling(call, tools)

        send(
          reply_to,
          {:octoroom_agent_async_tool_result,
           %{
             call_id: Map.get(call, :id),
             name: Map.get(call, :name),
             args: Map.get(call, :args),
             response: Map.get(response, :response, response),
             scheduling: scheduling,
             event: event
           }}
        )
      end)
    end)
  end
end
