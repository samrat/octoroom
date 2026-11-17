defmodule Octoroom.Agent.Cascaded.ReqLLMChat do
  @moduledoc false

  # Chat-completion turns through ReqLLM. `:provider` is a ReqLLM provider atom
  # (`:google`, `:openrouter`, ...); `:provider_options` passes provider-specific
  # request options through untouched.

  alias ReqLLM.Context
  alias Octoroom.Agent.Tool
  alias ReqLLM.Response
  alias ReqLLM.ToolCall

  def run_turn(opts) do
    model = Keyword.fetch!(opts, :model)
    input = Keyword.fetch!(opts, :input)
    tools = Keyword.get(opts, :tools, [])
    max_tokens = Keyword.get(opts, :max_tokens)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)

    request_opts =
      [
        tools: Enum.map(tools, &to_req_llm_tool/1),
        tool_choice: :auto
      ]
      |> maybe_put(:max_tokens, max_tokens)
      |> maybe_put(:reasoning_effort, reasoning_effort)
      |> maybe_put(:provider_options, Keyword.get(opts, :provider_options))

    with {:ok, response} <-
           ReqLLM.generate_text(
             %{provider: Keyword.get(opts, :provider, :google), id: model},
             input,
             request_opts
           ) do
      classified = Response.classify(response)
      function_calls = Enum.map(classified.tool_calls, &normalize_tool_call/1)

      {:ok,
       %{
         text: String.trim(classified.text || ""),
         function_calls: function_calls,
         continuation: [assistant_message(classified)]
       }}
    end
  end

  def stream_turn(opts) do
    model = Keyword.fetch!(opts, :model)
    input = Keyword.fetch!(opts, :input)
    tools = Keyword.get(opts, :tools, [])
    max_tokens = Keyword.get(opts, :max_tokens)
    reasoning_effort = Keyword.get(opts, :reasoning_effort)
    on_event = Keyword.get(opts, :on_event, fn _event -> :ok end)
    stream_fun = Keyword.get(opts, :stream_fun, &ReqLLM.stream_text/3)

    process_stream_fun =
      Keyword.get(opts, :process_stream_fun, &ReqLLM.StreamResponse.process_stream/2)

    request_opts =
      [
        tools: Enum.map(tools, &to_req_llm_tool/1),
        tool_choice: :auto
      ]
      |> maybe_put(:max_tokens, max_tokens)
      |> maybe_put(:reasoning_effort, reasoning_effort)
      |> maybe_put(:provider_options, Keyword.get(opts, :provider_options))

    with {:ok, stream_response} <-
           stream_fun.(
             %{provider: Keyword.get(opts, :provider, :google), id: model},
             input,
             request_opts
           ),
         {:ok, response} <-
           process_stream_fun.(stream_response, stream_callbacks(on_event)) do
      classified = Response.classify(response)
      function_calls = Enum.map(classified.tool_calls, &normalize_tool_call/1)
      emit_final_events(on_event, response, function_calls)

      {:ok,
       %{
         text: String.trim(classified.text || ""),
         function_calls: function_calls,
         continuation: [assistant_message(classified)]
       }}
    end
  end

  def tool_result_messages(tool_outputs) do
    Enum.map(tool_outputs, fn output ->
      Context.tool_result(output.call_id, output.name, output.response)
    end)
  end

  defp to_req_llm_tool(%Tool{} = tool) do
    ReqLLM.tool(
      name: tool.name,
      description: tool.description,
      parameter_schema: tool.parameters,
      callback: fn _args -> {:ok, %{}} end
    )
  end

  defp stream_callbacks(on_event) do
    [
      on_result: fn text -> on_event.({:text_delta, text}) end,
      on_thinking: fn text -> on_event.({:thinking_delta, text}) end,
      on_tool_call: fn chunk ->
        on_event.({:tool_call_delta, normalize_stream_tool_call(chunk)})
      end,
      on_meta: fn chunk -> on_event.({:metadata, chunk.metadata || %{}}) end
    ]
  end

  defp normalize_stream_tool_call(chunk) do
    %{
      id: Map.get(chunk.metadata || %{}, :id) || Map.get(chunk.metadata || %{}, "id"),
      name: chunk.name,
      args: chunk.arguments || %{},
      metadata: chunk.metadata || %{}
    }
  end

  defp emit_final_events(on_event, response, function_calls) do
    if function_calls != [] do
      on_event.({:tool_calls, function_calls})
    end

    on_event.(
      {:done,
       %{
         finish_reason: Map.get(response, :finish_reason),
         usage: Map.get(response, :usage),
         provider_meta: Map.get(response, :provider_meta, %{})
       }}
    )
  end

  defp normalize_tool_call(%ToolCall{} = call) do
    %{
      id: call.id,
      name: ToolCall.name(call),
      args: ToolCall.args_map(call) || %{}
    }
  end

  defp normalize_tool_call(%{id: id, name: name, arguments: arguments}) do
    %{id: id, name: name, args: normalize_args(arguments)}
  end

  defp normalize_tool_call(%{"id" => id, "name" => name, "arguments" => arguments}) do
    %{id: id, name: name, args: normalize_args(arguments)}
  end

  defp normalize_tool_call(%{id: id, function: %{name: name, arguments: arguments}}) do
    %{id: id, name: name, args: normalize_args(arguments)}
  end

  defp normalize_tool_call(%{
         "id" => id,
         "function" => %{"name" => name, "arguments" => arguments}
       }) do
    %{id: id, name: name, args: normalize_args(arguments)}
  end

  defp normalize_tool_call(call), do: %{id: nil, name: nil, args: call}

  defp assistant_message(%{tool_calls: [_ | _] = calls}) do
    Context.assistant("", tool_calls: Enum.map(calls, &to_req_llm_tool_call/1))
  end

  defp assistant_message(%{text: text}) do
    Context.assistant(text || "")
  end

  defp to_req_llm_tool_call(%{id: id, name: name, arguments: arguments}) do
    ToolCall.new(id, name, Jason.encode!(arguments || %{}))
  end

  defp to_req_llm_tool_call(%{"id" => id, "name" => name, "arguments" => arguments}) do
    ToolCall.new(id, name, Jason.encode!(arguments || %{}))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp normalize_args(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp normalize_args(arguments) when is_map(arguments), do: arguments
  defp normalize_args(_arguments), do: %{}
end
