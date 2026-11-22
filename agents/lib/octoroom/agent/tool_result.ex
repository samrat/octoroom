defmodule Octoroom.Agent.ToolResult do
  @moduledoc false

  defstruct [:call_id, :name, response: %{}, event: nil]

  @max_args_chars 300
  @max_response_chars 1_000

  @doc """
  Builds a compact, serializable summary of a completed tool call for
  persisting in `Octoroom.Store` and restoring agent context on restart.
  """
  def summary(attrs) when is_map(attrs) do
    entry = %{
      call_id: Map.get(attrs, :call_id) || Map.get(attrs, :id),
      name: Map.get(attrs, :name),
      args: compact_args(Map.get(attrs, :args)),
      response: compact(Map.get(attrs, :response), @max_response_chars)
    }

    case Map.get(attrs, :at) do
      at when is_integer(at) -> Map.put(entry, :at, at)
      _ -> entry
    end
  end

  @doc """
  Formats a tool call summary as a single compact line, e.g.
  `check_availability({"date":"2026-11-27"}) -> {"slots":["09:00"]}`.
  """
  def format(%{name: name} = entry) do
    args = compact_args(Map.get(entry, :args))
    response = compact(Map.get(entry, :response), @max_response_chars)

    if is_nil(args),
      do: "#{name}() -> #{response}",
      else: "#{name}(#{args}) -> #{response}"
  end

  defp compact_args(nil), do: nil
  defp compact_args(""), do: nil
  defp compact_args("{}"), do: nil
  defp compact_args(map) when is_map(map) and map_size(map) == 0, do: nil
  defp compact_args(args), do: compact(args, @max_args_chars)

  defp compact(value, max_chars) do
    encoded =
      cond do
        is_binary(value) ->
          value

        true ->
          case Jason.encode(value) do
            {:ok, json} -> json
            {:error, _reason} -> inspect(value)
          end
      end

    truncate(encoded, max_chars)
  end

  defp truncate(str, max_chars) do
    if String.length(str) > max_chars,
      do: String.slice(str, 0, max_chars) <> "…",
      else: str
  end
end
