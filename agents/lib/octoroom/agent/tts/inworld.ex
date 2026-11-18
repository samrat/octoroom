defmodule Octoroom.Agent.TTS.Inworld do
  @moduledoc """
  Inworld text-to-speech.

  Reads `INWORLD_API_KEY` (the Base64 key Inworld's dashboard shows). Besides
  `Octoroom.Agent.TTS`'s options it takes `:audio_encoding`, `:delivery_mode`,
  `:timestamp_transport_strategy`, `:receive_timeout` and:

    * `:transport` - `:http` (the default) or `:websocket`. Over HTTP each
      call is a request; `:stream` (`true`, the default) uses the streaming
      endpoint and `false` makes one plain request. Over `:websocket` each
      call is a context on Inworld's bidirectional stream, on the connection
      `connect/1` opened (the TTS processor opens one per agent), so replies
      after the first skip the connection setup. Without one, a call opens
      its own connection and closes it after.
  """

  @behaviour Octoroom.Agent.TTS

  alias Octoroom.Agent.SpeechProvider
  alias Octoroom.Agent.TTS.Inworld.Socket

  @speech_url "https://api.inworld.ai/tts/v1/voice"
  @speech_stream_url "https://api.inworld.ai/tts/v1/voice:stream"
  @stream_buffer_key :octoroom_agent_inworld_stream_buffer

  @impl true
  def default_options do
    [
      model: "inworld-tts-2",
      voice: "Ashley",
      audio_encoding: "LINEAR16",
      sample_rate: 24_000,
      stream: true,
      transport: :http
    ]
  end

  @doc """
  Opens the WebSocket that `:websocket` calls share, closed when the calling
  process exits. Returns the options with it as `:connection`. Does nothing
  over HTTP.
  """
  @impl true
  def connect(opts) do
    with :websocket <- transport(opts),
         nil <- Keyword.get(opts, :connection),
         {:ok, token} <- SpeechProvider.api_key(opts, "INWORLD_API_KEY"),
         {:ok, socket} <- Socket.start(token, socket_opts(opts)) do
      {:ok, Keyword.put(opts, :connection, socket)}
    else
      {:error, reason} -> {:error, reason}
      _http_or_connected -> {:ok, opts}
    end
  end

  @impl true
  def stream(text, on_audio, opts) do
    cond do
      transport(opts) == :websocket ->
        websocket_speech(text, on_audio, opts)

      Keyword.get(opts, :stream, true) ->
        stream_speech(text, on_audio, opts)

      true ->
        with {:ok, audio} <- synthesize(text, opts) do
          on_audio.(audio)
          :ok
        end
    end
  end

  @impl true
  def synthesize(input, opts) do
    with {:ok, token} <- SpeechProvider.api_key(opts, "INWORLD_API_KEY") do
      speech(input, token, opts)
    end
  end

  defp speech(input, token, opts) do
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
        case Socket.decode_audio(audio) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:error, :invalid_inworld_audio_content}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:inworld_speech_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stream_speech(input, on_audio, opts) do
    with {:ok, token} <- SpeechProvider.api_key(opts, "INWORLD_API_KEY") do
      stream_speech(input, on_audio, token, opts)
    end
  end

  defp stream_speech(input, on_audio, token, opts) do
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

  defp websocket_speech(text, on_audio, opts) do
    with {:ok, token} <- SpeechProvider.api_key(opts, "INWORLD_API_KEY") do
      timeout = Keyword.get(opts, :receive_timeout, 60_000)
      config = Map.delete(stream_payload(text, opts), :text)

      case Keyword.get(opts, :connection) do
        socket when is_pid(socket) ->
          if Process.alive?(socket),
            do: Socket.speak(socket, text, config, on_audio, timeout),
            else: one_shot(token, text, config, on_audio, timeout, opts)

        nil ->
          one_shot(token, text, config, on_audio, timeout, opts)
      end
    end
  end

  # No shared connection, or it gave up reconnecting: one just for this call.
  defp one_shot(token, text, config, on_audio, timeout, opts) do
    with {:ok, socket} <- Socket.start(token, socket_opts(opts)) do
      try do
        Socket.speak(socket, text, config, on_audio, timeout)
      after
        Socket.stop(socket)
      end
    end
  end

  defp socket_opts(opts), do: Keyword.take(opts, [:url])

  defp transport(opts) do
    case Keyword.get(opts, :transport, :http) do
      transport when transport in [:websocket, "websocket"] -> :websocket
      _http -> :http
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
    case Socket.decode_audio(audio) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> :skip
    end
  end

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
