defmodule Octoroom.InletTest do
  use ExUnit.Case, async: true

  alias Octoroom.Inlet

  # 20 ms of room PCM.
  @frame :binary.copy(<<0>>, 3_840)

  setup do
    room_id = "inlet-#{System.unique_integer([:positive])}"
    # The test stands in for the worker the inlet forwards to.
    {:ok, _} = Registry.register(Octoroom.Registry, {:worker, room_id, "w"}, nil)

    start = fn burst_ms, format ->
      opts = %{
        room_id: room_id,
        worker_id: "w",
        input: "a/mic",
        burst_ms: burst_ms,
        format: format
      }

      {:ok, pid} = Inlet.start_link(opts)
      pid
    end

    %{start: start}
  end

  defp push(inlet, n), do: for(_ <- 1..n, do: send(inlet, {:octoroom_pcm, self(), @frame}))

  defp forwarded(timeout \\ 50) do
    receive do
      {:octoroom_input, "a/mic", _, _} -> 1 + forwarded(timeout)
    after
      timeout -> 0
    end
  end

  test "passes a burst up to the bucket and drops the rest", ctx do
    inlet = ctx.start.(100, {48_000, 2})
    push(inlet, 12)
    # 100 ms of tokens is five frames (plus whatever refilled meanwhile).
    n = forwarded()
    assert n in 5..6
    assert %{forwarded: ^n, dropped: dropped} = Inlet.stats(inlet)
    assert dropped == 12 - n
  end

  test "refills at real time", ctx do
    inlet = ctx.start.(40, {48_000, 2})
    push(inlet, 10)
    assert forwarded() in 2..3

    Process.sleep(100)
    push(inlet, 10)
    # 100 ms more, capped at the 40 ms bucket: two frames.
    assert forwarded() == 2
  end

  test "holds a fast stream to real time", ctx do
    inlet = ctx.start.(60, {48_000, 2})
    started = System.monotonic_time(:millisecond)

    # Two frames every 30 ms: a third faster than real time. (Sleeps run
    # long, never short, so the stream is at least this fast.)
    for _ <- 1..20 do
      push(inlet, 2)
      Process.sleep(30)
    end

    elapsed = System.monotonic_time(:millisecond) - started
    n = forwarded()
    # No more than real time plus the 60 ms bucket.
    assert n <= div(elapsed, 20) + 3
    assert %{dropped: dropped} = Inlet.stats(inlet)
    assert dropped >= 1
  end

  test "puts RTP back in order and decodes it", ctx do
    inlet = ctx.start.(300, {48_000, 2})
    encoder = Membrane.Opus.Encoder.Native.create(48_000, 2, 2048, -1000, 3001)

    packets =
      for seq <- 0..2 do
        {:ok, payload} = Membrane.Opus.Encoder.Native.encode_packet(encoder, @frame, 960)
        ExRTP.Packet.new(payload, sequence_number: seq, timestamp: seq * 960)
      end

    for i <- [0, 2, 1], do: send(inlet, {:octoroom_rtp, Enum.at(packets, i)})

    # Released after the jitter buffer's latency, as 20 ms of room PCM each.
    for _ <- 1..3 do
      assert_receive {:octoroom_input, "a/mic", pcm, {48_000, 2}}, 200
      assert byte_size(pcm) == 3_840
    end
  end

  test "decodes mono packets straight to the worker's format", ctx do
    inlet = ctx.start.(300, {16_000, 1})
    encoder = Membrane.Opus.Encoder.Native.create(48_000, 1, 2048, -1000, 3001)

    {:ok, payload} =
      Membrane.Opus.Encoder.Native.encode_packet(encoder, binary_part(@frame, 0, 1_920), 960)

    send(inlet, {:octoroom_rtp, ExRTP.Packet.new(payload, sequence_number: 0, timestamp: 0)})

    # 20 ms of 16 kHz mono.
    assert_receive {:octoroom_input, "a/mic", pcm, {16_000, 1}}, 200
    assert byte_size(pcm) == 640
  end

  test "converts room PCM, and follows a new format", ctx do
    inlet = ctx.start.(300, {16_000, 1})
    push(inlet, 1)
    assert_receive {:octoroom_input, "a/mic", pcm, {16_000, 1}}, 200
    assert byte_size(pcm) == 640

    send(inlet, {:octoroom_format, {24_000, 2}})
    push(inlet, 1)
    assert_receive {:octoroom_input, "a/mic", pcm, {24_000, 2}}, 200
    assert byte_size(pcm) == 1_920
  end
end
