defmodule Octoroom.Agent.Tool do
  @moduledoc false

  @default_progress_delay_ms 700

  @behaviors [:blocking, :non_blocking]
  @schedulings [:interrupt, :when_idle, :silent]

  # `progress_message` is spoken while a blocking tool runs, if the result
  # has not arrived within `progress_delay_ms`. Only the cascaded backend
  # speaks it.
  #
  # `behavior: :non_blocking` lets the conversation continue while the tool
  # runs; when the result arrives, `scheduling` decides what happens:
  # `:interrupt` (speak about it now), `:when_idle` (after the current reply)
  # or `:silent` (add it to the context only). Only the cascaded backend
  # supports it; Gemini Live runs non-blocking tools as blocking.
  defstruct [
    :name,
    :description,
    :parameters,
    :handler,
    :progress_message,
    progress_delay_ms: @default_progress_delay_ms,
    behavior: :blocking,
    scheduling: :when_idle
  ]

  def behaviors, do: @behaviors
  def schedulings, do: @schedulings

  @doc "The tool definition for a call, or `nil`."
  def find(call, tools) when is_list(tools),
    do: Enum.find(tools, &(&1.name == Map.get(call, :name)))

  @doc "True if the call's tool is non-blocking."
  def non_blocking?(call, tools) do
    match?(%__MODULE__{behavior: :non_blocking}, find(call, tools))
  end

  @doc "The call's default scheduling (`:when_idle` for unknown tools)."
  def scheduling(call, tools) do
    case find(call, tools) do
      %__MODULE__{scheduling: scheduling} when scheduling in @schedulings -> scheduling
      _tool -> :when_idle
    end
  end

  @doc """
  Returns `{message, delay_ms}` for the first call whose tool has a progress
  message, or `nil`.
  """
  def progress_for(calls, tools) when is_list(calls) and is_list(tools) do
    Enum.find_value(calls, fn call ->
      case Enum.find(tools, &(&1.name == Map.get(call, :name))) do
        %__MODULE__{progress_message: message} = tool
        when is_binary(message) and message != "" ->
          {message, progress_delay(tool)}

        _tool ->
          nil
      end
    end)
  end

  defp progress_delay(%__MODULE__{progress_delay_ms: delay})
       when is_integer(delay) and delay >= 0,
       do: delay

  defp progress_delay(_tool), do: @default_progress_delay_ms
end
