defmodule Octoroom.Agent.OpenAILive.Sideband do
  @moduledoc false

  # Sideband WebSocket attached to an active OpenAI Live WebRTC session
  # (`wss://api.openai.com/v1/live/sessions/{session_id}/attach`).
  #
  # Sends `parent` `{:openai_live_sideband, event}` for each decoded server
  # event (excluding reflected audio deltas, which arrive over WebRTC RTP),
  # plus `:connected` and `{:disconnected, reason}`. Reconnects with backoff
  # unless explicitly closed via `close/1`.

  use WebSockex

  alias Octoroom.Agent.OpenAILive.Protocol

  @reconnect_base_ms 250
  @reconnect_max_ms 5_000

  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)
    api_key = Keyword.fetch!(opts, :api_key)

    WebSockex.start_link(
      url,
      __MODULE__,
      %{
        parent: Keyword.fetch!(opts, :parent),
        closing?: false,
        notified_disconnect?: false
      },
      extra_headers: [{"Authorization", "Bearer #{api_key}"}],
      async: true,
      handle_initial_conn_failure: true
    )
  end

  def send_json(pid, frame) when is_map(frame), do: WebSockex.cast(pid, {:send_json, frame})
  def close(pid), do: WebSockex.cast(pid, :close)

  @impl true
  def handle_connect(_conn, state) do
    send(state.parent, {:openai_live_sideband, :connected})
    {:ok, %{state | notified_disconnect?: false}}
  end

  @impl true
  def handle_cast({:send_json, frame}, state), do: {:reply, {:text, Jason.encode!(frame)}, state}

  def handle_cast(:close, state) do
    {:reply, {:text, Jason.encode!(Protocol.session_close_frame())}, %{state | closing?: true}}
  end

  @impl true
  def handle_frame(frame, state) do
    case Protocol.decode_frame(frame) do
      {:ok, events} ->
        Enum.each(events, fn
          # Audio arrives paced over the WebRTC Opus track; drop reflected WS audio.
          {:audio, _pcm, _opts} -> :ok
          event -> send(state.parent, {:openai_live_sideband, event})
        end)

        {:ok, state}

      {:error, reason} ->
        send(state.parent, {:openai_live_sideband, {:decode_error, reason}})
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
        send(state.parent, {:openai_live_sideband, {:disconnected, disconnect.reason}})
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
