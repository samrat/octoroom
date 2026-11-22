defmodule Octoroom.Agent.GeminiLive.WebSocket do
  @moduledoc false

  # One Gemini Live connection. Sends `parent` `{:gemini_live_socket, event}`
  # for each decoded event (see `Protocol`), plus `:connected` and
  # `{:disconnected, reason}`. It reconnects with backoff, and with the
  # latest resumption handle, so the model keeps the conversation when the
  # server closes the connection (it does after about 10 minutes).
  #
  # `:handle` resumes a session from an earlier process (an agent that
  # restarted). If a connection that offered a handle closes before setup
  # completes, the handle is taken to be rejected (expired, say): the next
  # connection starts a new session with `:fallback_setup`, and the parent
  # gets `:resumption_failed`.

  use WebSockex

  alias Octoroom.Agent.GeminiLive.Protocol

  @endpoint "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
  @reconnect_base_ms 250
  @reconnect_max_ms 5_000

  def start_link(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    setup = Keyword.fetch!(opts, :setup)

    WebSockex.start_link(
      "#{Keyword.get(opts, :endpoint, @endpoint)}?key=#{URI.encode_www_form(api_key)}",
      __MODULE__,
      %{
        parent: Keyword.fetch!(opts, :parent),
        # Protocol.setup_frame/1 options; the handle is added to them.
        setup: setup,
        fallback_setup: Keyword.get(opts, :fallback_setup, setup),
        handle: Keyword.get(opts, :handle),
        # This connection offered a handle and setup hasn't completed.
        resuming?: false,
        notified_disconnect?: false
      },
      async: true,
      handle_initial_conn_failure: true
    )
  end

  def send_audio(pid, audio, opts \\ []) when is_binary(audio),
    do: send_json(pid, Protocol.audio_input_frame(audio, opts))

  def send_video(pid, data, opts \\ []) when is_binary(data),
    do: send_json(pid, Protocol.video_input_frame(data, opts))

  def send_audio_end(pid), do: send_json(pid, Protocol.audio_stream_end_frame())

  def send_text(pid, text) when is_binary(text),
    do: send_json(pid, Protocol.text_input_frame(text))

  def send_tool_response(pid, responses) when is_list(responses),
    do: send_json(pid, Protocol.tool_response_frame(responses))

  def send_json(pid, frame) when is_map(frame), do: WebSockex.cast(pid, {:send_json, frame})

  @impl true
  def handle_connect(_conn, state) do
    setup = Protocol.setup_frame(Keyword.put(state.setup, :resumption_handle, state.handle))
    WebSockex.cast(self(), {:send_json, setup})
    send(state.parent, {:gemini_live_socket, :connected})
    {:ok, %{state | notified_disconnect?: false, resuming?: state.handle != nil}}
  end

  @impl true
  def handle_cast({:send_json, frame}, state), do: {:reply, {:text, Jason.encode!(frame)}, state}

  @impl true
  def handle_frame(frame, state) do
    case Protocol.decode_frame(frame) do
      {:ok, events} ->
        state =
          Enum.reduce(events, state, fn event, state ->
            send(state.parent, {:gemini_live_socket, event})

            case event do
              {:resumption, handle} -> %{state | handle: handle}
              :setup_complete -> %{state | resuming?: false}
              _ -> state
            end
          end)

        {:ok, state}

      {:error, reason} ->
        send(state.parent, {:gemini_live_socket, {:decode_error, reason}})
        {:ok, state}
    end
  end

  @impl true
  def handle_disconnect(disconnect, state) do
    state =
      if state.notified_disconnect? do
        state
      else
        send(state.parent, {:gemini_live_socket, {:disconnected, disconnect.reason}})
        %{state | notified_disconnect?: true}
      end

    state =
      if state.resuming? do
        send(state.parent, {:gemini_live_socket, :resumption_failed})
        %{state | handle: nil, resuming?: false, setup: state.fallback_setup}
      else
        state
      end

    Process.sleep(reconnect_delay_ms(disconnect))
    {:reconnect, state}
  end

  defp reconnect_delay_ms(%{attempt_number: attempt}) do
    exponent = min(max(attempt, 1) - 1, 10)
    min(@reconnect_base_ms * Integer.pow(2, exponent), @reconnect_max_ms)
  end
end
