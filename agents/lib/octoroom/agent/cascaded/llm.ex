defmodule Octoroom.Agent.Cascaded.LLM do
  @moduledoc false

  # Chat turns go through ReqLLM. Subvocal's direct OpenAI client isn't
  # copied; OpenAI models can go through ReqLLM when wanted.

  alias Octoroom.Agent.Cascaded.ReqLLMChat

  @req_llm_providers [:google, :openrouter]

  def run_turn(opts) do
    case Keyword.fetch!(opts, :provider) do
      provider when provider in @req_llm_providers -> ReqLLMChat.run_turn(opts)
      provider -> {:error, {:unsupported_cascaded_llm_provider, provider}}
    end
  end

  def stream_turn(opts) do
    case Keyword.fetch!(opts, :provider) do
      provider when provider in @req_llm_providers -> ReqLLMChat.stream_turn(opts)
      provider -> {:error, {:unsupported_cascaded_llm_provider, provider}}
    end
  end

  def tool_result_messages(provider, tool_outputs) when provider in @req_llm_providers,
    do: ReqLLMChat.tool_result_messages(tool_outputs)
end
