defmodule Octoroom.Agent.ToolDispatcher do
  @moduledoc false

  require Logger

  alias Octoroom.Agent.Tool

  def handle_calls(calls, tools, context) when is_list(calls) and is_list(tools) do
    Enum.map_reduce(calls, context || %{}, fn call, context ->
      handle_call(call, tools, context)
    end)
  end

  defp handle_call(%{name: name} = call, tools, context) do
    tools
    |> Enum.find(&(&1.name == name))
    |> dispatch(call, context)
  end

  defp dispatch(%Tool{handler: {module, function}}, call, context) do
    case apply(module, function, [call, context]) do
      {response, event, context} ->
        log_tool_result(call, response)
        {{response, event}, context}

      {response, event} ->
        log_tool_result(call, response)
        {{response, event}, context}

      response when is_map(response) ->
        log_tool_result(call, response)
        {{response, nil}, context}
    end
  end

  defp dispatch(nil, %{id: id, name: name}, context) do
    response = %{id: id, name: name, response: %{result: "error", reason: "Unknown tool"}}
    log_tool_result(%{id: id, name: name}, response)
    {{response, nil}, context}
  end

  defp log_tool_result(call, response) do
    result = get_in(response, [:response, :result])
    reason = get_in(response, [:response, :reason])
    id = Map.get(call, :id)
    name = Map.get(call, :name)
    args = Map.get(call, :args)

    if result == "error" do
      Logger.warning(
        "TOOL_CALL name=#{name} id=#{inspect(id)} result=error reason=#{inspect(reason)} args=#{inspect(args)}"
      )
    else
      Logger.info(
        "TOOL_CALL name=#{name} id=#{inspect(id)} result=#{inspect(result)} args=#{inspect(args)}"
      )
    end
  end
end
