defmodule Octoroom.Agent.Cascaded.SonioxSocket do
  @moduledoc false

  use WebSockex

  require Logger

  @endpoint "wss://stt-rt.soniox.com/transcribe-websocket"

  # Soniox closes a stream that gets nothing for ~20 s (408). A browser
  # sends no packets while its mic is digitally silent, so a quiet person's
  # stream would time out: send a keepalive after this long without audio.
  @keepalive_ms 5_000

  def start_link(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    parent = Keyword.fetch!(opts, :parent)
    config = config(api_key, opts)

    WebSockex.start_link(
      @endpoint,
      __MODULE__,
      %{
        parent: parent,
        final_tokens: [],
        config: config,
        terminating?: false,
        last_audio: System.monotonic_time(:millisecond)
      },
      async: true,
      handle_initial_conn_failure: true,
      extra_headers: [{"Authorization", "Bearer #{api_key}"}]
    )
  end

  def send_audio(pid, audio) when is_binary(audio) do
    WebSockex.cast(pid, {:send_audio, audio})
  end

  def terminate_session(pid) do
    WebSockex.cast(pid, :terminate_session)
  end

  @doc """
  Finalizes all audio sent so far instead of waiting for Soniox's endpointing.
  Soniox answers with a `<fin>` token, which always produces a
  `{:transcription_final, text}` event, with empty text if nothing was pending.
  """
  def finalize(pid) do
    WebSockex.cast(pid, :finalize)
  end

  @impl true
  def handle_connect(_conn, state) do
    send(self(), :send_config)
    {:ok, state}
  end

  @impl true
  def handle_info(:send_config, state) do
    send(self(), :notify_connected)
    {:reply, {:text, Jason.encode!(state.config)}, state}
  end

  def handle_info(:notify_connected, state) do
    send(state.parent, {:soniox_socket, self(), :connected})
    Process.send_after(self(), :keepalive, @keepalive_ms)
    {:ok, state}
  end

  def handle_info(:keepalive, state) do
    Process.send_after(self(), :keepalive, @keepalive_ms)
    now = System.monotonic_time(:millisecond)

    if now - state.last_audio >= @keepalive_ms and not state.terminating?,
      do: {:reply, {:text, Jason.encode!(%{"type" => "keepalive"})}, %{state | last_audio: now}},
      else: {:ok, state}
  end

  @impl true
  def handle_frame({:text, frame}, state) do
    case Jason.decode(frame) do
      {:ok, event} -> dispatch_event(event, state)
      {:error, reason} -> {:ok, notify(state, {:decode_error, reason})}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:send_audio, audio}, state) when byte_size(audio) > 0 do
    {:reply, {:binary, audio}, Map.put(state, :last_audio, System.monotonic_time(:millisecond))}
  end

  def handle_cast({:send_audio, _audio}, state), do: {:ok, state}

  def handle_cast(:finalize, state) do
    {:reply, {:text, Jason.encode!(%{"type" => "finalize"})}, state}
  end

  def handle_cast(:terminate_session, state) do
    {:reply, {:text, ""}, %{state | terminating?: true}}
  end

  @impl true
  def handle_disconnect(disconnect, state) do
    notify(state, {:disconnected, disconnect.reason, %{intentional?: state.terminating?}})
    {:ok, state}
  end

  defp dispatch_event(%{"error_code" => code} = event, state) when not is_nil(code) do
    {:ok, notify(state, {:error, event})}
  end

  defp dispatch_event(%{"tokens" => tokens} = event, state) when is_list(tokens) do
    {final_text, state} = collect_tokens(tokens, state)

    cond do
      final_text != "" or manual_finalize?(tokens) ->
        notify(state, {:transcription_final, final_text})
        {:ok, %{state | final_tokens: []}}

      Map.get(event, "finished") ->
        state = flush_final_tokens(state)
        notify(state, :finished)
        {:ok, state}

      true ->
        notify_partial(tokens, state)
        {:ok, state}
    end
  end

  defp dispatch_event(%{"finished" => true}, state) do
    state = flush_final_tokens(state)
    notify(state, :finished)
    {:ok, state}
  end

  defp dispatch_event(event, state) do
    Logger.debug("Unhandled Soniox event: #{inspect(event)}")
    {:ok, state}
  end

  defp collect_tokens(tokens, state) do
    Enum.reduce(tokens, {"", state}, fn token, {final_text, state} ->
      case token do
        %{"text" => marker, "is_final" => true} when marker in ["<end>", "<fin>"] ->
          {render_final_tokens(state), state}

        %{"text" => text, "is_final" => true} when is_binary(text) and text != "" ->
          {final_text, %{state | final_tokens: state.final_tokens ++ [text]}}

        _token ->
          {final_text, state}
      end
    end)
  end

  defp manual_finalize?(tokens),
    do: Enum.any?(tokens, &match?(%{"text" => "<fin>", "is_final" => true}, &1))

  defp flush_final_tokens(state) do
    text = render_final_tokens(state)

    if text != "" do
      notify(state, {:transcription_final, text})
    end

    %{state | final_tokens: []}
  end

  defp notify_partial(tokens, state) do
    non_final_text =
      tokens
      |> Enum.filter(fn token -> !Map.get(token, "is_final", false) end)
      |> Enum.map_join("", &Map.get(&1, "text", ""))

    text =
      state
      |> render_final_tokens()
      |> Kernel.<>(non_final_text)
      |> String.trim()

    if text != "" do
      notify(state, {:transcription_partial, text})
    end
  end

  defp render_final_tokens(state), do: state.final_tokens |> Enum.join("") |> String.trim()

  defp notify(state, event) do
    send(state.parent, {:soniox_socket, self(), event})
    state
  end

  defp config(api_key, opts) do
    audio_format = Keyword.get(opts, :audio_format, "pcm_s16le")

    %{
      api_key: api_key,
      model: Keyword.get(opts, :model, "stt-rt-v5"),
      audio_format: audio_format,
      sample_rate: maybe_raw_audio_value(audio_format, Keyword.get(opts, :sample_rate, 16_000)),
      num_channels: maybe_raw_audio_value(audio_format, Keyword.get(opts, :num_channels, 1)),
      language_hints: Keyword.get(opts, :language_hints),
      enable_endpoint_detection: Keyword.get(opts, :enable_endpoint_detection, true),
      endpoint_latency_adjustment_level: Keyword.get(opts, :endpoint_latency_adjustment_level),
      endpoint_sensitivity: Keyword.get(opts, :endpoint_sensitivity),
      max_endpoint_delay_ms: Keyword.get(opts, :max_endpoint_delay_ms)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp maybe_raw_audio_value("auto", _value), do: nil
  defp maybe_raw_audio_value(_audio_format, value), do: value
end
