defmodule Octoroom.Agent.Cascaded.Inworld do
  @moduledoc false

  @speech_url "https://api.inworld.ai/tts/v1/voice"
  @speech_stream_url "https://api.inworld.ai/tts/v1/voice:stream"
  @stream_buffer_key :octoroom_agent_inworld_stream_buffer

  def speech(opts) do
    token = Keyword.fetch!(opts, :token)
    input = Keyword.fetch!(opts, :input)
    model = value(opts, :model, "inworld-tts-2")
    voice = value(opts, :voice, "Ashley")
    audio_encoding = value(opts, :audio_encoding, "LINEAR16")
    sample_rate = value(opts, :sample_rate, 24_000)
    request_fun = Keyword.get(opts, :request_fun, &Req.post/2)

    payload = %{
      text: input,
      voice_id: voice,
      model_id: model,
      audio_config: %{
        audio_encoding: audio_encoding,
        sample_rate_hertz: sample_rate
      }
    }

    case request_fun.(@speech_url,
           json: payload,
           headers: auth_headers(token),
           receive_timeout: 60_000
         ) do
      {:ok, %{status: status, body: %{"audioContent" => audio}}}
      when status in 200..299 and is_binary(audio) ->
        case Base.decode64(audio) do
          {:ok, decoded} -> {:ok, strip_wav_header(decoded)}
          :error -> {:error, :invalid_inworld_audio_content}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:inworld_speech_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def stream_speech(opts) do
    token = Keyword.fetch!(opts, :token)
    input = Keyword.fetch!(opts, :input)
    on_audio = Keyword.get(opts, :on_audio, fn _audio -> :ok end)
    request_fun = Keyword.get(opts, :request_fun, &Req.post/2)

    payload = stream_payload(input, opts)

    into = fn {:data, data}, {req, resp} ->
      buffer = Map.get(resp.private, @stream_buffer_key, "")
      {events, buffer} = decode_stream_events(buffer <> data)

      Enum.each(events, fn event ->
        case audio_from_event(event) do
          {:ok, audio} -> on_audio.(audio)
          :skip -> :ok
        end
      end)

      resp = put_in(resp.private[@stream_buffer_key], buffer)
      {:cont, {req, resp}}
    end

    case request_fun.(@speech_stream_url,
           json: payload,
           headers: auth_headers(token),
           into: into,
           decode_body: false,
           receive_timeout: 60_000
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:inworld_stream_speech_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_payload(input, opts) do
    %{
      text: input,
      voiceId: value(opts, :voice, "Ashley"),
      modelId: value(opts, :model, "inworld-tts-2"),
      audioConfig: %{
        audioEncoding: value(opts, :audio_encoding, "LINEAR16"),
        sampleRateHertz: value(opts, :sample_rate, 24_000)
      }
    }
    |> maybe_put(:deliveryMode, Keyword.get(opts, :delivery_mode))
    |> maybe_put(:timestampTransportStrategy, Keyword.get(opts, :timestamp_transport_strategy))
  end

  defp decode_stream_events(buffer) do
    case decode_single_event(buffer) do
      {:ok, event} ->
        {[event], ""}

      :error ->
        decode_stream_lines(buffer)
    end
  end

  defp decode_single_event(buffer) do
    with text when text != "" <- String.trim(buffer),
         {:ok, decoded} <- Jason.decode(text) do
      {:ok, decoded}
    else
      _ -> :error
    end
  end

  defp decode_stream_lines(buffer) do
    {lines, rest} =
      if String.ends_with?(buffer, "\n") do
        {String.split(buffer, "\n", trim: true), ""}
      else
        [rest | lines] = buffer |> String.split("\n") |> Enum.reverse()
        {Enum.reverse(lines), rest}
      end

    events =
      lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, decoded} -> [decoded]
          {:error, _reason} -> []
        end
      end)

    {events, rest}
  end

  defp audio_from_event(%{"result" => %{"audioContent" => audio}}) when is_binary(audio),
    do: decode_audio(audio)

  defp audio_from_event(%{"result" => %{"audioChunk" => %{"audioContent" => audio}}})
       when is_binary(audio),
       do: decode_audio(audio)

  defp audio_from_event(%{"audioContent" => audio}) when is_binary(audio), do: decode_audio(audio)
  defp audio_from_event(_event), do: :skip

  defp decode_audio(audio) do
    case Base.decode64(audio) do
      {:ok, decoded} -> {:ok, strip_wav_header(decoded)}
      :error -> :skip
    end
  end

  defp strip_wav_header(<<"RIFF", _rest::binary>> = audio) do
    case :binary.match(audio, "data") do
      {index, 4} when byte_size(audio) >= index + 8 ->
        data_start = index + 8
        binary_part(audio, data_start, byte_size(audio) - data_start)

      _no_data_chunk ->
        audio
    end
  end

  defp strip_wav_header(audio), do: audio

  defp auth_headers(token) do
    [
      {"Authorization", "Basic #{token}"},
      {"Content-Type", "application/json"}
    ]
  end

  defp value(opts, key, default) do
    case Keyword.get(opts, key) do
      nil -> default
      value -> value
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
