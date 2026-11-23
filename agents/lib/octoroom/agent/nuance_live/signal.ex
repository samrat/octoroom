defmodule Octoroom.Agent.NuanceLive.Signal do
  @moduledoc false

  # LiveKit RTC signaling WebSocket (`/rtc?access_token=...`) speaking binary
  # Protobuf `SignalRequest` / `SignalResponse` frames.

  use WebSockex

  require Logger

  alias Octoroom.Agent.NuanceLive.Protobuf

  def start_link(opts) do
    url = Keyword.fetch!(opts, :url)
    parent = Keyword.fetch!(opts, :parent)
    state = %{parent: parent, closing?: false}
    WebSockex.start_link(url, __MODULE__, state)
  end

  @doc "Builds the LiveKit `/rtc` WebSocket URL from `livekit_url` and room `token`."
  def rtc_url(livekit_url, token) when is_binary(livekit_url) and is_binary(token) do
    base =
      livekit_url
      |> String.trim_trailing("/")
      |> String.replace_prefix("https://", "wss://")
      |> String.replace_prefix("http://", "ws://")

    base = if String.ends_with?(base, "/rtc"), do: base, else: base <> "/rtc"

    query =
      URI.encode_query(%{
        "access_token" => token,
        "auto_subscribe" => "1",
        "sdk" => "js",
        "protocol" => "15",
        "version" => "2.9.0"
      })

    "#{base}?#{query}"
  end

  def send_proto(pid, binary) when is_pid(pid) and is_binary(binary) do
    WebSockex.cast(pid, {:send, {:binary, binary}})
  end

  def close(pid) when is_pid(pid) do
    WebSockex.cast(pid, :close)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def handle_connect(_conn, state) do
    send(state.parent, {:livekit_signal, :connected})
    {:ok, state}
  end

  @impl true
  def handle_frame({:binary, data}, state) do
    case Protobuf.decode_signal_response(data) do
      {:ok, event} ->
        send(state.parent, {:livekit_signal, event})

      {:error, reason} ->
        Logger.warning("LiveKit signal decode error: #{inspect(reason)}")
    end

    {:ok, state}
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:send, frame}, state), do: {:reply, frame, state}
  def handle_cast(:close, state), do: {:close, %{state | closing?: true}}

  @impl true
  def handle_disconnect(_status, %{closing?: true} = state), do: {:ok, state}

  def handle_disconnect(%{reason: reason}, state) do
    send(state.parent, {:livekit_signal, {:disconnected, reason}})
    {:ok, state}
  end
end
