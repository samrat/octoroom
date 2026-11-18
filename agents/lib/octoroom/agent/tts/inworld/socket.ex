defmodule Octoroom.Agent.TTS.Inworld.Socket do
  @moduledoc false

  # One connection to Inworld's bidirectional TTS WebSocket, shared by every
  # `speak/4`. Each call is its own Inworld context: `create`, the text,
  # `flushContext`, `closeContext`; audio goes to the caller until
  # `contextClosed`. A caller that dies mid-reply (an interruption cancels
  # the TTS task) gets its context cancelled.
  #
  # Inworld closes a connection after 10 idle minutes, so the socket
  # reconnects when it drops, and stops after a few failed attempts in a
  # row. Contexts in flight when it drops fail.

  use WebSockex

  require Logger

  @endpoint "wss://api.inworld.ai/tts/v1/voice:streamBidirectional"

  # Inworld takes at most 2,000 characters (UTF-16 code units) per sendText.
  @max_text_units 2_000
  @max_attempts 3

  @doc """
  Connects. With `:owner` (default: the caller), the socket closes when its
  owner exits.
  """
  def start(token, opts) do
    owner = Keyword.get(opts, :owner, self())

    WebSockex.start(
      Keyword.get(opts, :url, @endpoint),
      __MODULE__,
      %{owner: owner, owner_ref: nil, contexts: %{}, next_id: 0},
      async: true,
      handle_initial_conn_failure: true,
      extra_headers: [{"Authorization", "Basic #{token}"}]
    )
  end

  @doc "Closes the connection."
  def stop(socket), do: WebSockex.cast(socket, :stop)

  @doc """
  Speaks `text` with the `create` config `config`, calling `on_audio` with
  each chunk of decoded audio. Waits up to `timeout` for each message.
  """
  def speak(socket, text, config, on_audio, timeout) do
    ref = make_ref()
    socket_ref = Process.monitor(socket)
    WebSockex.cast(socket, {:speak, self(), ref, text, config})

    try do
      await(socket, ref, socket_ref, on_audio, timeout)
    after
      Process.demonitor(socket_ref, [:flush])
    end
  end

  defp await(socket, ref, socket_ref, on_audio, timeout) do
    receive do
      {^ref, {:audio, audio}} ->
        on_audio.(audio)
        await(socket, ref, socket_ref, on_audio, timeout)

      {^ref, :done} ->
        :ok

      {^ref, {:error, reason}} ->
        {:error, reason}

      {:DOWN, ^socket_ref, :process, _pid, reason} ->
        {:error, {:inworld_socket_down, reason}}
    after
      timeout ->
        WebSockex.cast(socket, {:cancel, ref})
        {:error, :inworld_socket_timeout}
    end
  end

  @impl true
  def handle_connect(_conn, %{owner_ref: nil} = state) do
    {:ok, %{state | owner_ref: Process.monitor(state.owner)}}
  end

  def handle_connect(_conn, state), do: {:ok, state}

  @impl true
  def handle_cast({:speak, caller, ref, text, config}, state) do
    id = "octoroom-#{state.next_id}"

    context = %{caller: caller, ref: ref, monitor: Process.monitor(caller)}

    frames =
      [message(id, :create, config)] ++
        Enum.map(text_parts(text), &message(id, :sendText, %{text: &1})) ++
        [message(id, :flushContext, %{}), message(id, :closeContext, %{})]

    state = %{state | next_id: state.next_id + 1, contexts: Map.put(state.contexts, id, context)}
    send_frames(frames, state)
  end

  def handle_cast({:cancel, ref}, state) do
    case Enum.find(state.contexts, fn {_id, context} -> context.ref == ref end) do
      {id, _context} -> cancel(id, state)
      nil -> {:ok, state}
    end
  end

  def handle_cast(:stop, state), do: {:close, state}

  @impl true
  def handle_info({:send_frames, frames}, state), do: send_frames(frames, state)

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:close, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.contexts, fn {_id, context} -> context.monitor == monitor end) do
      {id, _context} -> cancel(id, state)
      nil -> {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_frame({:text, frame}, state) do
    case Jason.decode(frame) do
      {:ok, %{"result" => result}} -> {:ok, handle_result(result, state)}
      {:ok, %{"error" => error}} -> {:ok, fail_context(error["contextId"], error, state)}
      {:ok, other} -> {:ok, log_unhandled(other, state)}
      {:error, reason} -> {:ok, log_unhandled({:decode_error, reason}, state)}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason, attempt_number: attempt}, state) do
    state = fail_all({:inworld_socket_disconnected, reason}, state)

    cond do
      match?({:local, _}, reason) -> {:ok, state}
      not Process.alive?(state.owner) -> {:ok, state}
      attempt >= @max_attempts -> {:ok, state}
      true -> {:reconnect, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    fail_all({:inworld_socket_closed, reason}, state)
    :ok
  end

  defp handle_result(%{"contextId" => id} = result, state) do
    case Map.fetch(state.contexts, id) do
      {:ok, context} -> handle_context_result(id, context, result, state)
      :error -> state
    end
  end

  defp handle_result(result, state), do: log_unhandled(result, state)

  defp handle_context_result(id, context, result, state) do
    status = Map.get(result, "status", %{})

    cond do
      Map.get(status, "code", 0) not in [0, nil] ->
        fail_context(id, status, state)

      Map.has_key?(result, "contextClosed") ->
        reply(context, :done)
        drop(id, state)

      audio = get_in(result, ["audioChunk", "audioContent"]) ->
        case decode_audio(audio) do
          {:ok, ""} -> :ok
          {:ok, pcm} -> reply(context, {:audio, pcm})
          :error -> Logger.warning("Inworld sent audio that isn't base64")
        end

        state

      true ->
        state
    end
  end

  defp send_frames([], state), do: {:ok, state}
  defp send_frames([frame], state), do: {:reply, frame, state}

  # WebSockex sends one frame per callback; the rest go out next.
  defp send_frames([frame | rest], state) do
    send(self(), {:send_frames, rest})
    {:reply, frame, state}
  end

  defp cancel(id, state) do
    state = drop(id, state)
    {:reply, message(id, :cancelContext, %{}), state}
  end

  defp fail_context(nil, error, state), do: log_unhandled(error, state)

  defp fail_context(id, error, state) do
    case Map.fetch(state.contexts, id) do
      {:ok, context} ->
        reply(context, {:error, {:inworld_speech_failed, error}})
        drop(id, state)

      :error ->
        state
    end
  end

  defp fail_all(reason, state) do
    Enum.each(state.contexts, fn {_id, context} -> reply(context, {:error, reason}) end)

    Enum.each(state.contexts, fn {_id, context} ->
      Process.demonitor(context.monitor, [:flush])
    end)

    %{state | contexts: %{}}
  end

  defp drop(id, state) do
    {context, contexts} = Map.pop(state.contexts, id)
    if context, do: Process.demonitor(context.monitor, [:flush])
    %{state | contexts: contexts}
  end

  defp reply(context, message), do: send(context.caller, {context.ref, message})

  defp log_unhandled(message, state) do
    Logger.debug("Unhandled Inworld socket message: #{inspect(message)}")
    state
  end

  defp message(id, kind, body), do: {:text, Jason.encode!(%{:contextId => id, kind => body})}

  @doc false
  def decode_audio(audio) do
    with {:ok, decoded} <- Base.decode64(audio), do: {:ok, strip_wav_header(decoded)}
  end

  @doc false
  def strip_wav_header(<<"RIFF", _rest::binary>> = audio) do
    case :binary.match(audio, "data") do
      {index, 4} when byte_size(audio) >= index + 8 ->
        data_start = index + 8
        binary_part(audio, data_start, byte_size(audio) - data_start)

      _no_data_chunk ->
        audio
    end
  end

  def strip_wav_header(audio), do: audio

  @doc false
  # Splits on whitespace so no part passes Inworld's limit.
  def text_parts(text) do
    text
    |> String.split(~r/(?<=\s)/u)
    |> Enum.reduce([], fn
      word, [current | rest] ->
        if utf16_units(current) + utf16_units(word) <= @max_text_units,
          do: [current <> word | rest],
          else: [word, current | rest]

      word, [] ->
        [word]
    end)
    |> Enum.reverse()
    |> Enum.flat_map(&hard_split/1)
  end

  # A single "word" over the limit (no whitespace) is cut by graphemes.
  defp hard_split(part) do
    if utf16_units(part) <= @max_text_units do
      [part]
    else
      part
      |> String.graphemes()
      |> Enum.chunk_while(
        "",
        fn g, acc ->
          if utf16_units(acc) + utf16_units(g) <= @max_text_units,
            do: {:cont, acc <> g},
            else: {:cont, acc, g}
        end,
        fn acc -> {:cont, acc, ""} end
      )
    end
  end

  defp utf16_units(text),
    do: text |> :unicode.characters_to_binary(:utf8, :utf16) |> byte_size() |> div(2)
end
