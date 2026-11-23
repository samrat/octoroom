defmodule Octoroom.Agent.TTS.OpenAI do
  @moduledoc """
  OpenAI text-to-speech (`/v1/audio/speech`).

  Reads `OPENAI_API_KEY`. OpenAI's raw PCM is 24 kHz only, so
  `:sample_rate` must be 24 000. Besides `Octoroom.Agent.TTS`'s options it
  takes `:instructions` (how to speak; `gpt-4o-mini-tts` only), `:speed`,
  and `:stream` (`true`, the default, passes audio on as it downloads).
  """

  @behaviour Octoroom.Agent.TTS

  alias Octoroom.Agent.SpeechProvider

  @speech_url "https://api.openai.com/v1/audio/speech"
  @sample_rate 24_000
  # A chunk can end mid-sample; the odd byte waits for the next one.
  @odd_byte_key :octoroom_agent_openai_odd_byte

  @impl true
  def default_options,
    do: [voice: "alloy", sample_rate: @sample_rate, stream: true]

  @impl true
  def synthesize(text, opts) do
    with {:ok, token} <- api_key(opts) do
      case request(opts).(@speech_url, request_options(text, token, opts)) do
        {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
          {:ok, body}

        response ->
          failed(response)
      end
    end
  end

  @impl true
  def stream(text, on_audio, opts) do
    if Keyword.get(opts, :stream, true) do
      stream_speech(text, on_audio, opts)
    else
      with {:ok, audio} <- synthesize(text, opts) do
        on_audio.(audio)
        :ok
      end
    end
  end

  defp stream_speech(text, on_audio, opts) do
    with {:ok, token} <- api_key(opts) do
      # An error's body is JSON, not audio: keep it for the error.
      into = fn {:data, data}, {req, resp} ->
        if resp.status in 200..299 do
          {whole, odd} = split_odd(Map.get(resp.private, @odd_byte_key, "") <> data)
          if whole != "", do: on_audio.(whole)
          {:cont, {req, put_in(resp.private[@odd_byte_key], odd)}}
        else
          {:cont, {req, %{resp | body: IO.iodata_to_binary([resp.body || "", data])}}}
        end
      end

      options = request_options(text, token, opts) ++ [into: into, decode_body: false]

      case request(opts).(@speech_url, options) do
        {:ok, %{status: status}} when status in 200..299 -> :ok
        response -> failed(response)
      end
    end
  end

  defp api_key(opts) do
    case Keyword.get(opts, :sample_rate, @sample_rate) do
      @sample_rate -> SpeechProvider.api_key(opts, "OPENAI_API_KEY")
      rate -> {:error, {:unsupported_sample_rate, rate, only: @sample_rate}}
    end
  end

  defp request(opts), do: Keyword.get(opts, :request_fun, &Req.post/2)

  defp request_options(text, token, opts) do
    payload =
      %{
        model: Keyword.fetch!(opts, :model),
        voice: Keyword.fetch!(opts, :voice),
        input: text,
        response_format: "pcm",
        instructions: Keyword.get(opts, :instructions),
        speed: Keyword.get(opts, :speed)
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    [
      json: payload,
      headers: [{"Authorization", "Bearer #{token}"}],
      receive_timeout: 60_000
    ]
  end

  defp split_odd(audio) when rem(byte_size(audio), 2) == 0, do: {audio, ""}

  defp split_odd(audio) do
    size = byte_size(audio) - 1
    <<whole::binary-size(^size), odd::binary>> = audio
    {whole, odd}
  end

  defp failed({:ok, %{status: status, body: body}}),
    do: {:error, {:openai_speech_failed, status, decode(body)}}

  defp failed({:error, reason}), do: {:error, reason}

  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end

  defp decode(body), do: body
end
