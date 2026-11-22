defmodule Octoroom.Agent.Processors.Tools do
  @moduledoc """
  Runs the LLM's tool calls.

  Blocking calls run in a task; their results go upstream to the context as
  `ToolResults`, which starts the next round. If a blocking call has a
  `progress_message` and the LLM said nothing before calling it, the message
  is spoken after `progress_delay_ms`.

  Non-blocking calls start in the background and get a placeholder result for
  this round. Their real results come back as
  `{:octoroom_agent_async_tool_result, result}` messages and go upstream as
  `AsyncToolResult`, according to the tool's `scheduling`:

    * `:silent` - at once (the context only notes it)
    * `:interrupt` - at once, interrupting the reply, unless the user is
      speaking
    * `:when_idle` - once the user isn't speaking and no reply is running

  Waiting results are postponed (this is a `Octoroom.Agent.Processor.StateMachine`
  with the states `:idle`, `:user_speaking` and `:responding`).

  Options (default to the host context's values): `:tools`, `:context`
  (the tools' context map). The agent worker sets the context's `:speaker`
  before each reply with an `{:octoroom_agent_speaker, participant}`
  message. Handlers run in the agent's process
  (`Octoroom.Agent.ToolExecutor`).
  """

  use Octoroom.Agent.Processor.StateMachine

  require Logger

  alias Octoroom.Agent.Cascaded.LLM
  alias Octoroom.Agent.Tool
  alias Octoroom.Agent.ToolExecutor
  alias Octoroom.Agent.ToolResult

  @async_placeholder %{
    status: "started",
    note:
      "This runs in the background and its result will arrive in a later message. " <>
        "Tell the user you're on it, and don't guess the result."
  }

  @impl true
  def init(opts, ctx) do
    {:ok, :idle,
     %{
       tools: Keyword.get(opts, :tools, Map.get(ctx, :tools, [])),
       context: Keyword.get(opts, :context, Map.get(ctx, :context, %{})) || %{},
       executor: [],
       runner: Map.get(ctx, :runner),
       tool_round?: false,
       progress_message: nil
     }}
  end

  @impl true
  def handle_event(%Frames.UserStartedSpeaking{} = frame, _state, data),
    do: {:next_state, :user_speaking, data, [{:push, frame, :downstream}]}

  def handle_event(%Frames.UserStoppedSpeaking{} = frame, _state, data),
    do: {:next_state, :idle, data, [{:push, frame, :downstream}]}

  def handle_event(%Frames.LLMResponseStart{} = frame, _state, data),
    do: {:next_state, :responding, %{data | tool_round?: false}, [{:push, frame, :downstream}]}

  def handle_event(%Frames.LLMResponseEnd{} = frame, :responding, %{tool_round?: false} = data),
    do: {:next_state, :idle, data, [{:push, frame, :downstream}]}

  def handle_event(%Frames.ToolCalls{} = frame, _state, data) do
    {async_calls, sync_calls} = Enum.split_with(frame.calls, &Tool.non_blocking?(&1, data.tools))
    tools = data.tools
    context = data.context
    executor = data.executor
    reply_to = data.runner

    run = fn _emit ->
      if async_calls != [] and is_pid(reply_to) do
        ToolExecutor.run_async(
          async_calls,
          tools,
          context,
          Keyword.put(executor, :reply_to, reply_to)
        )
      end

      {results, context} =
        if sync_calls == [],
          do: {[], context},
          else: ToolExecutor.run(sync_calls, tools, context, executor)

      {results, context}
    end

    progress =
      case not frame.spoke? and sync_calls != [] and Tool.progress_for(sync_calls, tools) do
        {message, delay_ms} -> [{:timer, :progress, delay_ms}] |> then(&{message, &1})
        _none -> {nil, []}
      end

    {progress_message, progress} = progress

    meta = %{
      provider: frame.provider,
      sync_tools: Enum.map(sync_calls, & &1.name),
      async_tools: Enum.map(async_calls, & &1.name),
      call_count: length(frame.calls)
    }

    {:keep_state, %{data | tool_round?: true, progress_message: progress_message},
     [{:push, frame, :downstream}, {:async, {:run, frame}, run, meta}] ++ progress}
  end

  # A blocking round finished.
  def handle_event({:async, {:run, calls}, {:done, {results, context}}}, _state, data) do
    sync_outputs =
      Enum.map(results, fn {response, _event} ->
        %{call_id: response.id, name: response.name, response: response.response}
      end)

    outputs =
      sync_outputs ++
        for call <- calls.calls, Tool.non_blocking?(call, data.tools) do
          %{call_id: call.id, name: call.name, response: @async_placeholder}
        end

    summaries = summarize(calls.calls, sync_outputs)

    events =
      for {_response, event} <- results, event != nil, do: {:notify, {:control, event}}

    messages =
      (calls.continuation || []) ++
        LLM.tool_result_messages(calls.provider || :google, in_order(calls.calls, outputs))

    {:keep_state, %{data | context: context},
     events ++
       [
         cancel_progress(),
         {:push, %Frames.ToolResults{messages: messages, results: summaries}, :upstream}
       ]}
  end

  def handle_event({:async, {:run, calls}, {:failed, reason}}, _state, data) do
    Logger.warning("tool calls failed: #{inspect(reason)}")

    outputs =
      Enum.map(calls.calls, &%{call_id: &1.id, name: &1.name, response: %{error: "Tool failed"}})

    summaries = summarize(calls.calls, outputs)

    messages =
      (calls.continuation || []) ++ LLM.tool_result_messages(calls.provider || :google, outputs)

    {:keep_state, data,
     [
       cancel_progress(),
       {:push, %Frames.ToolResults{messages: messages, results: summaries}, :upstream}
     ]}
  end

  def handle_event({:timer, :progress}, :responding, %{progress_message: message} = data)
      when is_binary(message),
      do:
        {:keep_state, %{data | progress_message: nil},
         [{:push, %Frames.LLMText{text: " " <> message}, :downstream}]}

  # The participant whose turn starts the next reply (nil for one the app
  # started), for handlers to authorize against.
  def handle_event({:info, {:octoroom_agent_speaker, speaker}}, _state, data),
    do: {:keep_state, %{data | context: Map.put(data.context, :speaker, speaker)}}

  def handle_event({:info, {:octoroom_agent_frames, frames}}, _state, data),
    do: {:keep_state, %{data | context: Map.put(data.context, :frames, frames)}}

  def handle_event({:info, {:octoroom_agent_async_tool_result, result}}, state, data) do
    event = if result[:event], do: [{:notify, {:control, result.event}}], else: []
    frame = {:push, %Frames.AsyncToolResult{result: result}, :upstream}

    case {result.scheduling, state} do
      {:silent, _state} ->
        {:keep_state, data, event ++ [frame]}

      # The event goes out when the result is delivered, not each time it waits.
      {:interrupt, :user_speaking} ->
        {:keep_state, data, [:postpone]}

      {:interrupt, :responding} ->
        {:next_state, :idle, data, event ++ [{:push, %Frames.Interruption{}, :downstream}, frame]}

      {:interrupt, :idle} ->
        {:keep_state, data, event ++ [frame]}

      {_when_idle, :idle} ->
        {:keep_state, data, event ++ [frame]}

      {_when_idle, _busy} ->
        Logger.info(
          "ASYNC_TOOL_RESULT name=#{result.name} scheduling=#{result.scheduling} queued"
        )

        {:keep_state, data, [:postpone]}
    end
  end

  def handle_event(%Frames.Interruption{}, _state, data),
    do: {:keep_state, %{data | tool_round?: false}, [cancel_progress()]}

  defp cancel_progress, do: {:cancel_timer, :progress}

  defp in_order(calls, outputs) do
    by_id = Map.new(outputs, &{&1.call_id, &1})

    if map_size(by_id) == length(calls),
      do: Enum.map(calls, &Map.fetch!(by_id, &1.id)),
      else: outputs
  end

  defp summarize(calls, outputs) do
    calls_by_id = Map.new(calls, &{&1.id, &1})
    by_id = Map.new(outputs, &{&1.call_id, &1})

    ordered =
      if map_size(by_id) == length(outputs),
        do: for(call <- calls, Map.has_key?(by_id, call.id), do: Map.fetch!(by_id, call.id)),
        else: outputs

    Enum.map(ordered, fn output ->
      args = calls_by_id |> Map.get(output.call_id, %{}) |> Map.get(:args)
      ToolResult.summary(Map.put(output, :args, args))
    end)
  end
end
