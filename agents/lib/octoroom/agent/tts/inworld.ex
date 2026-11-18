defmodule Octoroom.Agent.TTS.Inworld do
  @moduledoc """
  Inworld text-to-speech, over its bidirectional WebSocket.

  Each call is a context on a connection. `connect/1` opens one to share
  (the TTS processor opens one per agent), so replies after the first skip
  the connection setup; without it, a call opens its own and closes it
  after.

  Reads `INWORLD_API_KEY` (the Base64 key Inworld's dashboard shows). Besides
  `Octoroom.Agent.TTS`'s options it takes `:audio_encoding`, `:delivery_mode`,
  `:timestamp_transport_strategy` and `:receive_timeout` (ms to wait for
  each message, default 60 s).
  """

  @behaviour Octoroom.Agent.TTS

  alias Octoroom.Agent.SpeechProvider
  alias Octoroom.Agent.TTS.Inworld.Socket

  @impl true
  def default_options do
    [
      model: "inworld-tts-2",
      voice: "Ashley",
      audio_encoding: "LINEAR16",
      sample_rate: 24_000
    ]
  end

  @doc """
  Opens a connection for calls to share, closed when the calling process
  exits. Returns the options with it as `:connection`. Without an API key it
  opens nothing, and calls report the missing key.
  """
  @impl true
  def connect(opts) do
    with nil <- Keyword.get(opts, :connection),
         {:ok, token} <- SpeechProvider.api_key(opts, "INWORLD_API_KEY"),
         {:ok, socket} <- Socket.start(token, socket_opts(opts)) do
      {:ok, Keyword.put(opts, :connection, socket)}
    else
      {:error, {:missing_env, _env}} -> {:ok, opts}
      {:error, reason} -> {:error, reason}
      _connected -> {:ok, opts}
    end
  end

  @impl true
  def stream(text, on_audio, opts) do
    with {:ok, token} <- SpeechProvider.api_key(opts, "INWORLD_API_KEY") do
      timeout = Keyword.get(opts, :receive_timeout, 60_000)
      config = config(opts)

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

  # The context's `create` message.
  defp config(opts) do
    %{
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

  defp value(opts, key, default) do
    case Keyword.get(opts, key) do
      nil -> default
      value -> value
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
