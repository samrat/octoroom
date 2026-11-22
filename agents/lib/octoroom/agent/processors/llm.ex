defmodule Octoroom.Agent.Processors.LLM do
  @moduledoc """
  Streams the LLM's reply for each `LLMContext`.

  Pushes `LLMResponseStart`, `LLMText` as text arrives, then `ToolCalls` if
  the model called tools, then `LLMResponseEnd`. Text after the first tool
  call isn't spoken: what came before it is the preamble ("let me check").
  An interruption kills the request.

  Options: `:provider` (`:google`, `:openrouter`, `:openai`) and `:model`,
  both needed; `:reasoning_effort`, `:max_tokens`, `:provider_options`,
  `:stream` (default `true`), `:token` (defaults to `OPENAI_API_KEY` for `:openai`;
  ReqLLM providers read their own keys), and `:request`, a
  `fn opts, emit -> {:ok, response} | {:error, reason} end` that replaces the
  provider (for tests; `emit.({:text_delta, text})` streams text, as the
  providers' `on_event` callback does).
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.Cascaded.LLM
  alias Octoroom.Agent.Frames

  @impl true
  def init(opts, ctx) do
    opts = opts |> LLM.normalize_opts() |> Map.new()

    with {:ok, request} <- request(opts) do
      provider = Map.get(opts, :provider)

      if is_pid(Map.get(ctx, :runner)) and not Map.has_key?(opts, :request) do
        warm_connection(provider)
      end

      {:ok,
       %{
         provider: provider,
         model: Map.get(opts, :model),
         request: request,
         stream?: Map.get(opts, :stream, true),
         tool_call_seen?: false,
         spoke?: false,
         preemptive: nil
       }}
    end
  end

  defp request(%{request: request}) when is_function(request, 2), do: {:ok, request}

  defp request(%{provider: provider, model: model} = opts)
       when is_atom(provider) and not is_nil(provider) and is_binary(model),
       do: {:ok, provider_request(provider, opts)}

  defp request(%{provider: provider}) when is_atom(provider) and not is_nil(provider),
    do: {:error, {:no_model, __MODULE__}}

  defp request(_opts), do: {:error, {:no_provider, __MODULE__}}

  defp provider_request(provider, opts) do
    token = Map.get(opts, :token) || if(provider == :openai, do: System.get_env("OPENAI_API_KEY"))

    base = [
      provider: provider,
      token: token,
      model: Map.fetch!(opts, :model),
      max_tokens: Map.get(opts, :max_tokens),
      reasoning_effort: Map.get(opts, :reasoning_effort),
      provider_options: Map.get(opts, :provider_options)
    ]

    fn request, emit ->
      request = Keyword.merge(base, request)

      if Keyword.get(request, :stream, true),
        do: LLM.stream_turn(Keyword.put(request, :on_event, emit)),
        else: LLM.run_turn(request)
    end
  end

  # Provider events are wrapped: a stream's own `{:done, metadata}` event must
  # not look like the task finishing.
  defp wrap(emit), do: fn event -> emit.({:llm_event, event}) end

  @impl true
  def handle_frame(
        %Frames.PreemptiveLLMContext{messages: messages, tools: tools},
        :downstream,
        state
      ) do
    request = state.request
    tools = tools || []
    opts = [input: messages, tools: tools, stream: state.stream?]

    meta = %{
      provider: state.provider,
      model: state.model,
      stream: state.stream?,
      preemptive: true,
      turn_id: nil,
      message_count: length(messages),
      tool_count: length(tools)
    }

    preemptive = %{
      key: preemptive_key(messages, tools),
      events: [],
      done: nil,
      promoted?: false
    }

    {[{:async, :preemptive, fn emit -> request.(opts, wrap(emit)) end, meta}],
     %{state | preemptive: preemptive}}
  end

  def handle_frame(%Frames.LLMContext{messages: messages, tools: tools}, :downstream, state) do
    tools = tools || []

    if preemptive_match?(state.preemptive, messages, tools) do
      promote_preemptive(state)
    else
      cancel = if state.preemptive, do: [{:cancel, :preemptive}], else: []
      request = state.request
      opts = [input: messages, tools: tools, stream: state.stream?]

      meta = %{
        provider: state.provider,
        model: state.model,
        stream: state.stream?,
        message_count: length(messages),
        tool_count: length(tools)
      }

      {cancel ++
         [
           {:push, %Frames.LLMResponseStart{}, :downstream},
           {:async, :reply, fn emit -> request.(opts, wrap(emit)) end, meta}
         ], %{state | tool_call_seen?: false, spoke?: false, preemptive: nil}}
    end
  end

  def handle_frame(
        %Frames.UserStartedSpeaking{} = frame,
        :downstream,
        %{preemptive: %{promoted?: false}} = state
      ) do
    {[{:cancel, :preemptive}, {:push, frame, :downstream}], %{state | preemptive: nil}}
  end

  def handle_frame(%Frames.Interruption{}, _direction, state),
    do: {[], %{state | tool_call_seen?: false, spoke?: false, preemptive: nil}}

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
  def handle_async(:preemptive, message, %{preemptive: %{promoted?: true}} = state) do
    {effects, state} = handle_async(:reply, message, state)

    state =
      case message do
        {:done, _} -> %{state | preemptive: nil}
        {:failed, _} -> %{state | preemptive: nil}
        _ -> state
      end

    {effects, state}
  end

  def handle_async(
        :preemptive,
        {:llm_event, event},
        %{preemptive: %{promoted?: false} = p} = state
      ) do
    {[], %{state | preemptive: %{p | events: [event | p.events]}}}
  end

  def handle_async(
        :preemptive,
        {:done, {:ok, _} = result},
        %{preemptive: %{promoted?: false} = p} = state
      ) do
    {[], %{state | preemptive: %{p | done: {:done, result}}}}
  end

  def handle_async(:preemptive, {status, _reason}, %{preemptive: %{promoted?: false}} = state)
      when status in [:done, :failed] do
    {[], %{state | preemptive: nil}}
  end

  def handle_async(:reply, {:llm_event, {:text_delta, text}}, %{tool_call_seen?: false} = state)
      when is_binary(text) and text != "",
      do: {[{:push, %Frames.LLMText{text: text}, :downstream}], %{state | spoke?: true}}

  def handle_async(:reply, {:llm_event, {:tool_call_delta, _call}}, state),
    do: {[], %{state | tool_call_seen?: true}}

  def handle_async(:reply, {:llm_event, _other}, state), do: {[], state}

  def handle_async(:reply, {:done, {:ok, response}}, state) do
    text =
      if state.stream? or Map.get(response, :text, "") in [nil, ""],
        do: [],
        else: [{:push, %Frames.LLMText{text: response.text}, :downstream}]

    calls =
      case Map.get(response, :function_calls, []) do
        [] ->
          []

        calls ->
          frame = %Frames.ToolCalls{
            calls: calls,
            continuation: Map.get(response, :continuation, []),
            provider: state.provider,
            spoke?: state.spoke? or text != []
          }

          [{:push, frame, :downstream}]
      end

    {text ++ calls ++ [{:push, %Frames.LLMResponseEnd{}, :downstream}], state}
  end

  def handle_async(:reply, {status, reason}, state) when status in [:done, :failed] do
    Logger.warning("LLM request failed: #{inspect(reason)}")

    {[
       {:notify, {:status, "Voice issue"}},
       {:error, reason, false},
       {:push, %Frames.LLMResponseEnd{}, :downstream}
     ], state}
  end

  def handle_async(_key, _message, state), do: {[], state}

  defp promote_preemptive(%{preemptive: p} = state) do
    state = %{state | tool_call_seen?: false, spoke?: false}

    {event_effects, state} =
      p.events
      |> Enum.reverse()
      |> Enum.reduce({[], state}, fn event, {acc, st} ->
        {more, st} = handle_async(:reply, {:llm_event, event}, st)
        {acc ++ more, st}
      end)

    case p.done do
      nil ->
        {[{:push, %Frames.LLMResponseStart{}, :downstream} | event_effects],
         %{state | preemptive: %{p | promoted?: true, events: []}}}

      done_msg ->
        {done_effects, state} = handle_async(:reply, done_msg, state)

        {[{:push, %Frames.LLMResponseStart{}, :downstream} | event_effects ++ done_effects],
         %{state | preemptive: nil}}
    end
  end

  defp preemptive_match?(%{promoted?: false, key: key}, messages, tools),
    do: key == preemptive_key(messages, tools)

  defp preemptive_match?(_preemptive, _messages, _tools), do: false

  defp preemptive_key(messages, tools) when is_list(messages) and messages != [] do
    {prefix, [last]} = Enum.split(messages, -1)
    {length(tools), prefix, normalize_last_message(last)}
  end

  defp preemptive_key(messages, tools), do: {length(tools), messages, nil}

  defp normalize_last_message(%{role: role, content: text}) when is_binary(text),
    do: {role, normalize_text(text)}

  defp normalize_last_message(other), do: other

  defp normalize_text(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]+/u, " ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp warm_connection(provider) do
    case warm_url(provider) do
      nil ->
        :ok

      url ->
        Task.start(fn ->
          try do
            Finch.build(:head, url)
            |> Finch.request(ReqLLM.Application.finch_name(), receive_timeout: 3_000)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end)
    end
  end

  defp warm_url(:openai), do: "https://api.openai.com/v1/models"
  defp warm_url(:openrouter), do: "https://openrouter.ai/api/v1/models"
  defp warm_url(:google), do: "https://generativelanguage.googleapis.com/v1beta/models"
  defp warm_url(:anthropic), do: "https://api.anthropic.com/v1/models"
  defp warm_url(:groq), do: "https://api.groq.com/openai/v1/models"
  defp warm_url(:cerebras), do: "https://api.cerebras.ai/v1/models"
  defp warm_url(_other), do: nil
end
