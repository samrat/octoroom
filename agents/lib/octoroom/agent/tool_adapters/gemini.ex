defmodule Octoroom.Agent.ToolAdapters.Gemini do
  @moduledoc false

  alias Octoroom.Agent.Tool

  def to_declarations(tools) when is_list(tools) do
    Enum.map(tools, &to_declaration/1)
  end

  def to_declaration(%Tool{} = tool) do
    %{
      functionDeclarations: [
        %{
          name: tool.name,
          description: tool.description,
          parameters: gemini_schema(tool.parameters)
        }
      ]
    }
  end

  defp gemini_schema(%{} = schema) do
    Map.new(schema, fn
      {:type, type} -> {:type, gemini_type(type)}
      {"type", type} -> {:type, gemini_type(type)}
      {key, value} -> {key, gemini_schema(value)}
    end)
  end

  defp gemini_schema(items) when is_list(items), do: Enum.map(items, &gemini_schema/1)
  defp gemini_schema(value), do: value

  defp gemini_type(type) when is_atom(type), do: type |> Atom.to_string() |> String.upcase()
  defp gemini_type(type) when is_binary(type), do: String.upcase(type)
end
