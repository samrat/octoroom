defmodule Octoroom.Agent.ToolAdapters.OpenAI do
  @moduledoc false

  alias Octoroom.Agent.Tool

  def to_responses_tools(tools) when is_list(tools) do
    Enum.map(tools, &to_responses_tool/1)
  end

  def to_responses_tool(%Tool{} = tool) do
    %{
      type: "function",
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters
    }
  end
end
