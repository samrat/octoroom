defmodule Octoroom.Agent.TTS.AssemblyAI do
  @moduledoc """
  AssemblyAI text-to-speech, over its streaming WebSocket.

  `connect/1` opens a session to share (the TTS processor opens one per
  agent), so replies after the first skip the connection setup; without
  it, a call opens its own and ends it after. The voice, model, language
  and sample rate are fixed for a session.

  Reads `ASSEMBLY_AI_API_KEY`. `:voice` is a voice slug such as `"aai-kyla"`
  (the default) or a cloned voice's id, and `:model` is
  `"assemblyai-tts-1"`. Besides `Octoroom.Agent.TTS`'s options it takes
  `:language` (`"english"`, `"spanish"`, `"german"`, `"italian"`,
  `"portuguese"` or `"french"`; by default the voice's), `:region` (`:us`,
  the default, or `:eu`) and `:receive_timeout` (ms to wait for each
  message, default 60 s).
  """

  @behaviour Octoroom.Agent.TTS

  alias Octoroom.Agent.SpeechProvider
  alias Octoroom.Agent.TTS.AssemblyAI.Socket

  @sample_rates [8_000, 16_000, 22_050, 24_000, 44_100, 48_000]

  @impl true
  def default_options,
    do: [voice: "aai-kyla", sample_rate: 24_000]

  @doc """
  Opens a session for calls to share, closed when the calling process
  exits. Returns the options with it as `:connection`. Without an API key it
  opens nothing, and calls report the missing key.
  """
  @impl true
  def connect(opts) do
    with nil <- Keyword.get(opts, :connection),
         {:ok, api_key} <- SpeechProvider.api_key(opts, "ASSEMBLY_AI_API_KEY"),
         {:ok, query} <- query(opts),
         {:ok, socket} <- Socket.start(api_key, query, socket_opts(opts)) do
      {:ok, Keyword.put(opts, :connection, socket)}
    else
      {:error, {:missing_env, _env}} -> {:ok, opts}
      {:error, reason} -> {:error, reason}
      _connected -> {:ok, opts}
    end
  end

  @impl true
  def stream(text, on_audio, opts) do
    with {:ok, api_key} <- SpeechProvider.api_key(opts, "ASSEMBLY_AI_API_KEY") do
      timeout = Keyword.get(opts, :receive_timeout, 60_000)

      case Keyword.get(opts, :connection) do
        socket when is_pid(socket) ->
          if Process.alive?(socket),
            do: Socket.speak(socket, text, on_audio, timeout),
            else: one_shot(api_key, text, on_audio, timeout, opts)

        nil ->
          one_shot(api_key, text, on_audio, timeout, opts)
      end
    end
  end

  # No shared session, or it gave up reconnecting: one just for this call.
  defp one_shot(api_key, text, on_audio, timeout, opts) do
    with {:ok, query} <- query(opts),
         {:ok, socket} <- Socket.start(api_key, query, socket_opts(opts)) do
      try do
        Socket.speak(socket, text, on_audio, timeout)
      after
        Socket.stop(socket)
      end
    end
  end

  defp socket_opts(opts) do
    case Keyword.get(opts, :url) do
      nil -> [url: endpoint(Keyword.get(opts, :region, :us))]
      url -> [url: url]
    end
  end

  defp endpoint(:eu), do: "wss://tts.eu.assemblyai.com/v1/ws"
  defp endpoint(_us), do: "wss://tts.us.assemblyai.com/v1/ws"

  @doc false
  # The connect query parameters.
  def query(opts) do
    rate = Keyword.get(opts, :sample_rate, 24_000)

    if rate in @sample_rates do
      {:ok,
       %{
         voice_id: Keyword.get(opts, :voice),
         model_id: Keyword.get(opts, :model),
         language: Keyword.get(opts, :language),
         sample_rate: rate,
         encoding: "pcm_s16le",
         word_boundaries: false
       }
       |> Enum.reject(fn {_key, value} -> is_nil(value) end)
       |> Map.new()}
    else
      {:error, {:unsupported_sample_rate, rate, @sample_rates}}
    end
  end
end
