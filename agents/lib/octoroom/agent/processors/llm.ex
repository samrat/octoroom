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
  def init(opts, _ctx) do
    opts = Map.new(opts)

    with {:ok, request} <- request(opts) do
      {:ok,
       %{
         provider: Map.get(opts, :provider),
         request: request,
         stream?: Map.get(opts, :stream, true),
         tool_call_seen?: false,
         spoke?: false
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
  def handle_frame(%Frames.LLMContext{messages: messages, tools: tools}, :downstream, state) do
    request = state.request
    opts = [input: messages, tools: tools || [], stream: state.stream?]

    {[
       {:push, %Frames.LLMResponseStart{}, :downstream},
       {:async, :reply, fn emit -> request.(opts, wrap(emit)) end}
     ], %{state | tool_call_seen?: false, spoke?: false}}
  end

  def handle_frame(%Frames.Interruption{}, _direction, state),
    do: {[], %{state | tool_call_seen?: false, spoke?: false}}

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
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
end
