defmodule Call.DelayEcho do
  @moduledoc """
  Plays back what it hears, two seconds late. `:flush` drops the two seconds
  it's holding and whatever is queued on its output.
  """
  use Octoroom.Worker, audio: [rate: 16_000, channels: 1]

  # 2 s of 16 kHz mono s16le.
  @delay_bytes 2 * 16_000 * 2

  @impl true
  def init(_args, _ctx), do: {:ok, <<>>}

  @impl true
  def handle_audio(_input, pcm, held) do
    held = held <> pcm

    case byte_size(held) - @delay_bytes do
      excess when excess > 0 ->
        <<out::binary-size(excess), held::binary>> = held
        {:ok, held, play: {:default, out}}

      _ ->
        {:ok, held}
    end
  end

  @impl true
  def handle_info(:flush, _held), do: {:ok, <<>>, flush: :default}
  def handle_info(_message, held), do: {:ok, held}
end

defmodule Call.Metronome do
  @moduledoc """
  A 100 ms beep at the top of every second. It makes audio from the wall
  clock in 100 ms batches, so the outlet's queue should stay short and flat;
  a growing queue or underruns point at pacing.
  """
  use Octoroom.Worker, audio: [rate: 16_000, channels: 1]

  @rate 16_000
  @batch_ms 100

  @impl true
  def init(_args, _ctx) do
    second =
      for i <- 0..(@rate - 1), into: <<>> do
        sample =
          if i < div(@rate, 10),
            do: round(6_000 * :math.sin(2 * :math.pi() * 880 * i / @rate)),
            else: 0

        <<sample::little-signed-16>>
      end

    send(self(), :tick)
    {:ok, %{second: second, started: System.monotonic_time(:millisecond), made: 0}}
  end

  @impl true
  def handle_audio(_input, _pcm, state), do: {:ok, state}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @batch_ms)
    due = div((System.monotonic_time(:millisecond) - state.started) * @rate, 1000)
    pcm = slice(state.second, state.made, due - state.made)
    {:ok, %{state | made: due}, play: {:default, pcm}}
  end

  def handle_info(_message, state), do: {:ok, state}

  # `count` samples of the looping one-second clip, starting at sample `from`.
  defp slice(_second, _from, count) when count <= 0, do: <<>>

  defp slice(second, from, count) do
    offset = rem(from, @rate)
    take = min(count, @rate - offset)
    binary_part(second, offset * 2, take * 2) <> slice(second, from + take, count - take)
  end
end

defmodule Call.Recorder do
  @moduledoc """
  Writes each input to its own WAV file (16 kHz mono) under the system's
  temp directory, and emits `{:recorded, %{track => seconds}, dir}` every
  second. Inputs that join later get a file of their own; the others carry
  on without a restart.
  """
  use Octoroom.Worker, audio: [rate: 16_000, channels: 1]

  @rate 16_000

  @impl true
  def init(_args, ctx) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    room = String.replace(ctx.room_id, ~r/[^A-Za-z0-9_-]/, "_")
    dir = Path.join([System.tmp_dir!(), "octoroom-recordings", room, stamp])
    File.mkdir_p!(dir)
    :timer.send_interval(1_000, :report)
    {:ok, %{dir: dir, files: %{}}}
  end

  @impl true
  def handle_audio(input, pcm, state) do
    {file, state} = file(state, input)
    # Positions are explicit: rewriting the header leaves the file's current
    # position undefined.
    :ok = :file.pwrite(file.io, 44 + file.bytes, pcm)
    {:ok, put_in(state.files[input].bytes, file.bytes + byte_size(pcm))}
  end

  @impl true
  def handle_info(:report, state) do
    Enum.each(state.files, fn {_, f} -> write_header(f) end)
    seconds = Map.new(state.files, fn {input, f} -> {input, f.bytes / (@rate * 2)} end)
    {:ok, state, emit: {:recorded, seconds, state.dir}}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    for {_, f} <- state.files do
      write_header(f)
      File.close(f.io)
    end
  end

  defp file(state, input) do
    case state.files[input] do
      nil ->
        name = String.replace(input, ~r/[^A-Za-z0-9_-]/, "_") <> ".wav"
        {:ok, io} = File.open(Path.join(state.dir, name), [:write, :binary, :raw])
        f = %{io: io, bytes: 0}
        write_header(f)
        {f, put_in(state.files[input], f)}

      f ->
        {f, state}
    end
  end

  # A 44-byte WAV header for `bytes` of 16 kHz mono s16le, written in place.
  defp write_header(%{io: io, bytes: bytes}) do
    header =
      <<"RIFF", 36 + bytes::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16, 1::little-16,
        @rate::little-32, @rate * 2::little-32, 2::little-16, 16::little-16, "data",
        bytes::little-32>>

    :ok = :file.pwrite(io, 0, header)
  end
end

defmodule Call.Captioner do
  @moduledoc """
  Live captions: streams every mic it hears to Soniox's real-time
  speech-to-text, one WebSocket per input, and emits
  `{:caption, track, %{text: text, done: done?}}` as words arrive. A line is
  `done` at the end of an utterance; until then its text may still change.

  Needs `config :call, soniox_api_key:`. After a restart (the room
  recovering) it starts over with new sockets: captions pause while it's
  down, and pick up again.
  """
  use Octoroom.Worker, audio: [rate: 16_000, channels: 1]

  require Logger

  @impl true
  def init(_args, ctx) do
    if ctx.resumed, do: Logger.info("Captioner resumed after #{ctx.resumed.gone_ms} ms")

    {:ok,
     %{key: Application.fetch_env!(:call, :soniox_api_key), inputs: %{}, sockets: %{}, wait: %{}}}
  end

  @impl true
  def handle_audio(input, pcm, state) do
    case socket(state, input) do
      {nil, state} ->
        {:ok, state}

      {socket, state} ->
        Call.SonioxSocket.send_audio(socket, pcm)
        {:ok, state}
    end
  end

  @impl true
  def handle_info({:soniox, socket, {kind, text}}, state) when kind in [:partial, :final] do
    case state.sockets[socket] do
      nil -> {:ok, state}
      input -> {:ok, state, emit: {:caption, input, %{text: text, done: kind == :final}}}
    end
  end

  def handle_info({:soniox, socket, {:closed, reason}}, state) do
    # Audio from that input opens a new one, after a pause so a bad key or
    # an outage doesn't become a reconnect loop.
    Logger.warning("Soniox socket closed: #{inspect(reason)}")

    case Map.pop(state.sockets, socket) do
      {nil, _} ->
        {:ok, state}

      {input, sockets} ->
        wait = Map.put(state.wait, input, System.monotonic_time(:millisecond) + 5_000)
        {:ok, %{state | sockets: sockets, inputs: Map.delete(state.inputs, input), wait: wait}}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  defp socket(state, input) do
    # Monotonic time can be negative: no entry means not waiting.
    waiting =
      case state.wait[input] do
        nil -> false
        until -> until > System.monotonic_time(:millisecond)
      end

    case state.inputs[input] do
      nil when waiting ->
        {nil, state}

      nil ->
        {:ok, socket} = Call.SonioxSocket.start_link(api_key: state.key, parent: self())
        state = %{state | inputs: Map.put(state.inputs, input, socket)}
        {socket, put_in(state.sockets[socket], input)}

      socket ->
        {socket, state}
    end
  end
end

defmodule Call.SonioxSocket do
  @moduledoc """
  One Soniox real-time transcription stream (16 kHz mono s16le in). Sends
  its parent `{:soniox, self(), {:partial, text}}` while an utterance is in
  progress, `{:final, text}` when it ends, and `{:closed, reason}`.
  """
  use WebSockex

  @endpoint "wss://stt-rt.soniox.com/transcribe-websocket"

  def start_link(opts) do
    state = %{
      parent: Keyword.fetch!(opts, :parent),
      key: Keyword.fetch!(opts, :api_key),
      final: "",
      configured: false
    }

    WebSockex.start_link(@endpoint, __MODULE__, state,
      async: true,
      handle_initial_conn_failure: true
    )
  end

  def send_audio(pid, pcm), do: WebSockex.cast(pid, {:audio, pcm})

  @impl true
  def handle_connect(_conn, state) do
    send(self(), :configure)
    {:ok, state}
  end

  @impl true
  def handle_info(:configure, state) do
    config = %{
      api_key: state.key,
      model: "stt-rt-v6",
      audio_format: "pcm_s16le",
      sample_rate: 16_000,
      num_channels: 1,
      enable_endpoint_detection: true
    }

    {:reply, {:text, Jason.encode!(config)}, %{state | configured: true}}
  end

  # Audio cast while connecting is queued ahead of `:configure`, and Soniox
  # closes a stream whose first message isn't its config: drop it.
  @impl true
  def handle_cast({:audio, pcm}, %{configured: true} = state), do: {:reply, {:binary, pcm}, state}
  def handle_cast({:audio, _pcm}, state), do: {:ok, state}

  @impl true
  def handle_frame({:text, json}, state) do
    case Jason.decode(json) do
      {:ok, %{"error_code" => code} = error} when code != nil ->
        {:close, notify(state, {:closed, error})}

      {:ok, %{"tokens" => tokens}} ->
        {:ok, tokens(tokens, state)}

      _ ->
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    notify(state, {:closed, reason})
    {:ok, state}
  end

  # Final tokens accumulate until `<end>` (end of utterance); non-final ones
  # are this moment's guess at the rest.
  defp tokens(tokens, state) do
    {final, ended} =
      Enum.reduce(tokens, {state.final, false}, fn
        %{"text" => "<end>", "is_final" => true}, {final, _} -> {final, true}
        %{"text" => text, "is_final" => true}, {final, ended} -> {final <> text, ended}
        _, acc -> acc
      end)

    guess = for %{"text" => t} = tok <- tokens, !tok["is_final"], into: "", do: t

    cond do
      ended and String.trim(final) != "" ->
        notify(state, {:final, String.trim(final)})
        %{state | final: ""}

      ended ->
        %{state | final: ""}

      String.trim(final <> guess) != "" ->
        notify(state, {:partial, String.trim(final <> guess)})
        %{state | final: final}

      true ->
        %{state | final: final}
    end
  end

  defp notify(state, event) do
    send(state.parent, {:soniox, self(), event})
    state
  end
end
