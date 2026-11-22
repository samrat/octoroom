defmodule Octoroom.Agent.Cascaded.LLM do
  @moduledoc false

  # Chat turns go through ReqLLM. Subvocal's direct OpenAI client isn't
  # copied; OpenAI models can go through ReqLLM when wanted.

  alias Octoroom.Agent.Cascaded.ReqLLMChat

  @req_llm_providers [:google, :openrouter, :openai, :anthropic, :groq, :cerebras]

  def providers, do: @req_llm_providers

  @doc false
  def normalize_opts(spec) when is_binary(spec) do
    case split_model(spec) do
      {:ok, provider, model} -> [provider: provider, model: model]
      :error -> [model: spec]
    end
  end

  def normalize_opts(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :provider) do
      opts
    else
      case Keyword.get(opts, :model) do
        model when is_binary(model) ->
          case split_model(model) do
            {:ok, provider, id} ->
              opts |> Keyword.put(:model, id) |> Keyword.put(:provider, provider)

            :error ->
              opts
          end

        _other ->
          opts
      end
    end
  end

  def normalize_opts(other), do: other

  defp split_model(spec) do
    with [prefix, id] <- String.split(spec, ":", parts: 2),
         true <- id != "",
         provider when not is_nil(provider) <-
           Enum.find(@req_llm_providers, &(Atom.to_string(&1) == prefix)) do
      {:ok, provider, id}
    else
      _ -> :error
    end
  end

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
