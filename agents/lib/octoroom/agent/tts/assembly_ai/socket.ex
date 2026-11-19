defmodule Octoroom.Agent.TTS.AssemblyAI.Socket do
  @moduledoc false

  # One session on AssemblyAI's streaming TTS WebSocket, shared by every
  # `speak/4`. The voice, model, language and sample rate are fixed when it
  # connects. A speak sends its text as `Generate` frames and a `Flush`;
  # AssemblyAI answers flushes one at a time, in order, so the audio goes to
  # the oldest speak until its `FlushDone`. Frames carry no id to cancel one
  # speak by, so a caller that dies mid-reply (an interruption cancels the
  # TTS task) gets a `Cancel`, which stops all of them: the others fail.
  #
  # Nothing is sent before `Begin`; what comes earlier waits. An idle
  # session closes after `inactivity_timeout` seconds (at most 120), so the
  # socket sends `KeepAlive` while idle, and a session ends after an hour,
  # so it reconnects when the connection drops, and stops after a few
  # failed attempts in a row, or after an error that retrying won't fix.
  # Speaks in flight when it drops fail, with the `Error` AssemblyAI sends
  # before closing when it sends one.

  use WebSockex

  require Logger

  alias Octoroom.Agent.TTS

  @endpoint "wss://tts.us.assemblyai.com/v1/ws"

  # AssemblyAI takes at most 2,000 code points per Generate.
  @max_text_chars 2_000
  @max_attempts 3
  @keep_alive_ms 30_000

  @doc """
  Connects with the connect `query` (a map of query parameters). With
  `:owner` (default: the caller), the socket closes when its owner exits.
  """
  def start(api_key, query, opts) do
    owner = Keyword.get(opts, :owner, self())
    url = Keyword.get(opts, :url, @endpoint) <> "?" <> URI.encode_query(query)

    WebSockex.start(url, __MODULE__, initial_state(owner),
      async: true,
      handle_initial_conn_failure: true,
      extra_headers: [{"Authorization", api_key}]
    )
  end

  @doc false
  def initial_state(owner) do
    %{
      owner: owner,
      owner_ref: nil,
      begun?: false,
      # Frames waiting for `Begin`.
      waiting: [],
      # Speaks whose flush hasn't finished, oldest first.
      speaks: [],
      # `Cancel`s not yet answered: audio until then is for cancelled speaks.
      cancels: 0,
      keep_alive: nil,
      # Set by an `Error` that retrying won't fix (a bad key or voice).
      fatal?: false
    }
  end

  @doc "Ends the session."
  def stop(socket), do: WebSockex.cast(socket, :stop)

  @doc """
  Speaks `text`, calling `on_audio` with each chunk of audio. Waits up to
  `timeout` for each message.
  """
  def speak(socket, text, on_audio, timeout) do
    ref = make_ref()
    socket_ref = Process.monitor(socket)
    WebSockex.cast(socket, {:speak, self(), ref, text})

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
        {:error, {:assembly_ai_socket_down, reason}}
    after
      timeout ->
        WebSockex.cast(socket, {:cancel, ref})
        {:error, :assembly_ai_socket_timeout}
    end
  end

  @impl true
  def handle_connect(_conn, %{owner_ref: nil} = state) do
    {:ok, %{state | owner_ref: Process.monitor(state.owner)}}
  end

  def handle_connect(_conn, state), do: {:ok, state}

  @impl true
  def handle_cast({:speak, caller, ref, text}, state) do
    speak = %{caller: caller, ref: ref, monitor: Process.monitor(caller)}

    frames =
      Enum.map(text_parts(text), &message("Generate", text: &1)) ++ [message("Flush")]

    send_frames(frames, %{state | speaks: state.speaks ++ [speak]})
  end

  def handle_cast({:cancel, ref}, state) do
    if Enum.any?(state.speaks, &(&1.ref == ref)), do: cancel(ref, state), else: {:ok, state}
  end

  def handle_cast(:stop, state) do
    fail_all(:assembly_ai_socket_stopped, state)
    {:close, %{state | speaks: []}}
  end

  @impl true
  def handle_info({:send_frames, frames}, state), do: send_frames(frames, state)

  def handle_info(:keep_alive, state) do
    state = schedule_keep_alive(%{state | keep_alive: nil})

    if state.begun? and state.speaks == [] and state.waiting == [],
      do: {:reply, message("KeepAlive"), state},
      else: {:ok, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:close, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case Enum.find(state.speaks, &(&1.monitor == monitor)) do
      %{ref: ref} -> cancel(ref, state)
      nil -> {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def handle_frame({:text, frame}, state) do
    case Jason.decode(frame) do
      {:ok, %{"type" => type} = message} -> handle_message(type, message, state)
      {:ok, other} -> {:ok, log_unhandled(other, state)}
      {:error, reason} -> {:ok, log_unhandled({:decode_error, reason}, state)}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason, attempt_number: attempt}, state) do
    state = fail_all({:assembly_ai_socket_disconnected, reason}, state)
    state = %{state | begun?: false, waiting: [], speaks: [], cancels: 0}

    cond do
      match?({:local, _}, reason) -> {:ok, state}
      state.fatal? -> {:ok, state}
      not Process.alive?(state.owner) -> {:ok, state}
      attempt >= @max_attempts -> {:ok, state}
      true -> {:reconnect, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    fail_all({:assembly_ai_socket_closed, reason}, state)
    :ok
  end

  defp handle_message("Begin", _message, state) do
    waiting = state.waiting
    send_frames(waiting, schedule_keep_alive(%{state | begun?: true, waiting: []}))
  end

  defp handle_message("Audio", %{"audio" => audio}, %{cancels: 0, speaks: [speak | _]} = state) do
    case Base.decode64(audio) do
      {:ok, ""} -> :ok
      {:ok, pcm} -> reply(speak, {:audio, pcm})
      :error -> Logger.warning("AssemblyAI sent audio that isn't base64")
    end

    {:ok, state}
  end

  defp handle_message("FlushDone", _message, %{cancels: 0, speaks: [speak | rest]} = state) do
    reply(speak, :done)
    Process.demonitor(speak.monitor, [:flush])
    {:ok, %{state | speaks: rest}}
  end

  defp handle_message("Cancelled", _message, %{cancels: cancels} = state) when cancels > 0,
    do: {:ok, %{state | cancels: cancels - 1}}

  # Sent before AssemblyAI closes the connection; the speaks in flight fail
  # with it rather than with the bare disconnect. One that retrying won't fix
  # stops the reconnecting; an idle timeout is the only harmless one.
  defp handle_message("Error", message, state) do
    Logger.warning("AssemblyAI TTS error: #{inspect(message)}")

    fatal? =
      message["retryable"] == false and message["error_type"] != "inactivity_timeout"

    state = %{state | fatal?: state.fatal? or fatal?}
    {:ok, fail_all({:assembly_ai_speech_failed, message}, state)}
  end

  defp handle_message(_type, _message, state), do: {:ok, state}

  # Every speak in flight stops; the others fail.
  defp cancel(ref, state) do
    Enum.each(state.speaks, fn speak ->
      if speak.ref != ref, do: reply(speak, {:error, :assembly_ai_speech_cancelled})
      Process.demonitor(speak.monitor, [:flush])
    end)

    state = %{state | speaks: []}

    if state.begun? do
      {:reply, message("Cancel"), %{state | cancels: state.cancels + 1}}
    else
      # Nothing has gone out: drop what was waiting instead.
      {:ok, %{state | waiting: []}}
    end
  end

  defp send_frames([], state), do: {:ok, state}

  defp send_frames(frames, %{begun?: false} = state),
    do: {:ok, %{state | waiting: state.waiting ++ frames}}

  defp send_frames([frame], state), do: {:reply, frame, state}

  # WebSockex sends one frame per callback; the rest go out next.
  defp send_frames([frame | rest], state) do
    send(self(), {:send_frames, rest})
    {:reply, frame, state}
  end

  defp schedule_keep_alive(%{keep_alive: nil} = state),
    do: %{state | keep_alive: Process.send_after(self(), :keep_alive, @keep_alive_ms)}

  defp schedule_keep_alive(state), do: state

  defp fail_all(reason, state) do
    Enum.each(state.speaks, fn speak ->
      reply(speak, {:error, reason})
      Process.demonitor(speak.monitor, [:flush])
    end)

    %{state | speaks: []}
  end

  defp reply(speak, message), do: send(speak.caller, {speak.ref, message})

  defp log_unhandled(message, state) do
    Logger.debug("Unhandled AssemblyAI TTS message: #{inspect(message)}")
    state
  end

  defp message(type, fields \\ []),
    do: {:text, Jason.encode!(Map.new([{:type, type} | fields]))}

  @doc false
  def text_parts(text), do: TTS.split_text(text, @max_text_chars, &code_points/1)

  defp code_points(text), do: text |> String.to_charlist() |> length()
end
