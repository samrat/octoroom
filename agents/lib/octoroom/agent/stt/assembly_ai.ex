defmodule Octoroom.Agent.STT.AssemblyAI do
  @moduledoc """
  AssemblyAI realtime speech-to-text over its v3 WebSocket API.

  Reads `ASSEMBLY_AI_API_KEY`. `:model` is AssemblyAI's `speech_model`:
  `"assemblyai-stt-3-7-realtime-agent"` (the default) for an agent that
  answers, which decides when a turn ends, or `"assemblyai-stt-3-7-realtime"`
  for captions and transcripts, which ignores the endpointing settings
  below. Both take 32 languages in one stream. The older Universal models
  still work by name.
  Besides `Octoroom.Agent.STT`'s options it takes `:format_turns` (default
  `false`: punctuated, cased finals cost latency) and the endpointing
  settings `:end_of_turn_confidence_threshold`,
  `:min_end_of_turn_silence_when_confident` and `:max_turn_silence`.
  """

  @behaviour Octoroom.Agent.STT

  use WebSockex

  require Logger

  alias Octoroom.Agent.{SpeechProvider, STT}

  @endpoint "wss://streaming.assemblyai.com/v3/ws"

  @query_options ~w(end_of_turn_confidence_threshold min_end_of_turn_silence_when_confident
                    max_turn_silence)a

  @impl STT
  def default_options,
    do: [model: "assemblyai-stt-3-7-realtime-agent", sample_rate: 16_000, format_turns: false]

  @impl STT
  def start_link(opts) do
    with {:ok, api_key} <- SpeechProvider.api_key(opts, "ASSEMBLY_AI_API_KEY") do
      format_turns = Keyword.get(opts, :format_turns, false)

      WebSockex.start_link(
        "#{@endpoint}?#{query(opts, format_turns)}",
        __MODULE__,
        %{
          owner: Keyword.get(opts, :owner, self()),
          format_turns: format_turns,
          # The current turn's transcript so far; `finalize/1` with nothing
          # pending answers at once, since AssemblyAI sends no turn for it.
          pending: "",
          terminating?: false
        },
        extra_headers: [{"Authorization", api_key}],
        async: true,
        handle_initial_conn_failure: true
      )
    end
  end

  @impl STT
  def send_audio(pid, audio) when is_binary(audio), do: WebSockex.cast(pid, {:send_audio, audio})

  @doc """
  Ends the current turn now instead of waiting for AssemblyAI's endpointing.
  Answered with `{:final, text}`, at once with `""` if nothing was pending.
  """
  @impl STT
  def finalize(pid), do: WebSockex.cast(pid, :finalize)

  @impl STT
  def close(pid), do: WebSockex.cast(pid, :terminate_session)

  defp query(opts, format_turns) do
    %{
      "sample_rate" => Keyword.fetch!(opts, :sample_rate),
      "encoding" => "pcm_s16le",
      "format_turns" => format_turns,
      "speech_model" => Keyword.get(opts, :model)
    }
    |> Map.merge(Map.new(@query_options, &{Atom.to_string(&1), Keyword.get(opts, &1)}))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> URI.encode_query()
  end

  @impl true
  def handle_connect(_conn, state) do
    STT.notify(state.owner, :connected)
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, frame}, state) do
    case Jason.decode(frame) do
      {:ok, event} -> {:ok, dispatch_event(event, state)}
      {:error, reason} -> {:ok, notify(state, {:warning, {:decode_error, reason}})}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:send_audio, audio}, state) when byte_size(audio) > 0,
    do: {:reply, {:binary, audio}, state}

  def handle_cast({:send_audio, _audio}, state), do: {:ok, state}

  def handle_cast(:finalize, %{pending: ""} = state), do: {:ok, notify(state, {:final, ""})}

  def handle_cast(:finalize, state),
    do: {:reply, {:text, Jason.encode!(%{"type" => "ForceEndpoint"})}, state}

  def handle_cast(:terminate_session, state) do
    {:reply, {:text, Jason.encode!(%{"type" => "Terminate"})}, %{state | terminating?: true}}
  end

  @impl true
  def handle_disconnect(disconnect, state) do
    notify(state, {:disconnected, disconnect.reason, %{intentional?: state.terminating?}})
    {:ok, state}
  end

  # With `format_turns`, an ended turn comes twice: unformatted with
  # `end_of_turn`, then formatted. Only the formatted one is final; the
  # other is a partial, and the turn stays pending until it's formatted.
  defp dispatch_event(%{"type" => "Turn", "transcript" => text} = event, state)
       when is_binary(text) do
    final? =
      if state.format_turns,
        do: Map.get(event, "turn_is_formatted", false),
        else: Map.get(event, "end_of_turn", false)

    cond do
      final? -> %{notify(state, {:final, String.trim(text)}) | pending: ""}
      String.trim(text) == "" -> state
      true -> %{notify(state, {:partial, String.trim(text)}) | pending: text}
    end
  end

  defp dispatch_event(%{"type" => "Termination"}, state), do: notify(state, :finished)

  defp dispatch_event(%{"type" => type}, state) when type in ["Begin", "SpeechStarted"],
    do: state

  defp dispatch_event(%{"error" => message}, state) when is_binary(message),
    do: notify(state, {:error, %{message: message}})

  defp dispatch_event(event, state) do
    Logger.debug("Unhandled AssemblyAI event: #{inspect(event)}")
    state
  end

  defp notify(state, event) do
    STT.notify(state.owner, event)
    state
  end
end
