defmodule Octoroom.Agent.OpenAILive.WebSocket do
  @moduledoc false

  # One OpenAI Live connection (`wss://api.openai.com/v1/live/sessions`).
  # Sends `parent` `{:openai_live_socket, event}` for each decoded event
  # (see `Protocol`), plus `:connected` and `{:disconnected, reason}`.
  # Reconnects with backoff unless closed explicitly via `close/1`.

  use WebSockex

  alias Octoroom.Agent.OpenAILive.Protocol

  @endpoint "wss://api.openai.com/v1/live/sessions"
  @reconnect_base_ms 250
  @reconnect_max_ms 5_000

  def start_link(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    setup = Keyword.fetch!(opts, :setup)
    sample_rate = Keyword.get(setup, :sample_rate, Protocol.default_sample_rate())

    WebSockex.start_link(
      Keyword.get(opts, :endpoint, @endpoint),
      __MODULE__,
      %{
        parent: Keyword.fetch!(opts, :parent),
        setup: setup,
        sample_rate: sample_rate,
        closing?: false,
        notified_disconnect?: false
      },
      extra_headers: [{"Authorization", "Bearer #{api_key}"}],
      async: true,
      handle_initial_conn_failure: true
    )
  end

  def send_audio(pid, audio) when is_binary(audio),
    do: send_json(pid, Protocol.audio_input_frame(audio))

  def send_mute(pid), do: send_json(pid, Protocol.input_audio_mute_frame())
  def send_unmute(pid), do: send_json(pid, Protocol.input_audio_unmute_frame())

  def send_instructions(pid, content, opts \\ []) when is_binary(content),
    do: send_json(pid, Protocol.instructions_append_frame(content, opts))

  def send_thinking(pid, content, opts \\ []) when is_binary(content),
    do: send_json(pid, Protocol.thinking_append_frame(content, opts))

  def send_commentary(pid, content, opts \\ []) when is_binary(content),
    do: send_json(pid, Protocol.commentary_append_frame(content, opts))

  def send_tool_output(pid, call_id, output) when is_binary(call_id),
    do: send_json(pid, Protocol.tool_output_frame(call_id, output))

  def send_response_create(pid), do: send_json(pid, Protocol.response_create_frame())

  def close(pid), do: WebSockex.cast(pid, :close)

  def send_json(pid, frame) when is_map(frame), do: WebSockex.cast(pid, {:send_json, frame})

  @impl true
  def handle_connect(_conn, state) do
    start_frame = Protocol.session_start_frame(state.setup)
    WebSockex.cast(self(), {:send_json, start_frame})
    send(state.parent, {:openai_live_socket, :connected})
    {:ok, %{state | notified_disconnect?: false}}
  end

  @impl true
  def handle_cast({:send_json, frame}, state), do: {:reply, {:text, Jason.encode!(frame)}, state}

  def handle_cast(:close, state) do
    {:reply, {:text, Jason.encode!(Protocol.session_close_frame())}, %{state | closing?: true}}
  end

  @impl true
  def handle_frame(frame, state) do
    case Protocol.decode_frame(frame, sample_rate: state.sample_rate) do
      {:ok, events} ->
        Enum.each(events, &send(state.parent, {:openai_live_socket, &1}))
        {:ok, state}

      {:error, reason} ->
        send(state.parent, {:openai_live_socket, {:decode_error, reason}})
        {:ok, state}
    end
  end

  @impl true
  def handle_disconnect(_disconnect, %{closing?: true} = state), do: {:ok, state}

  def handle_disconnect(disconnect, state) do
    state =
      if state.notified_disconnect? do
        state
      else
        send(state.parent, {:openai_live_socket, {:disconnected, disconnect.reason}})
        %{state | notified_disconnect?: true}
      end

    Process.sleep(reconnect_delay_ms(disconnect))
    {:reconnect, state}
  end

  defp reconnect_delay_ms(%{attempt_number: attempt}) do
    exponent = min(max(attempt, 1) - 1, 10)
    min(@reconnect_base_ms * Integer.pow(2, exponent), @reconnect_max_ms)
  end
end
