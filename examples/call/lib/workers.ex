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
