defmodule Octoroom.OutletTest do
  use ExUnit.Case, async: true

  alias Octoroom.Outlet

  @frame 3_840

  setup do
    room_id = "outlet-#{System.unique_integer([:positive])}"
    {:ok, pid} = Outlet.start_link(%{room_id: room_id, name: "out", server: self()})
    %{room_id: room_id, outlet: pid}
  end

  # The test is the sink: it receives `{:octoroom_pcm, frame}`. The outlet
  # sends a frame of silence and goes live at once.
  defp connect(ctx) do
    test = self()
    send(ctx.outlet, {:octoroom_sink, {:pcm, &send(test, {:octoroom_pcm, &1})}})
    assert_receive {:octoroom_pcm, silence}
    assert silence == :binary.copy(<<0>>, @frame)
    assert_receive {:outlet_live, "out", pid}
    assert pid == ctx.outlet
  end

  defp frames(n, byte \\ 1), do: :binary.copy(<<byte>>, n * @frame)

  defp collect(timeout) do
    receive do
      {:octoroom_pcm, frame} -> [{System.monotonic_time(:millisecond), frame} | collect(timeout)]
    after
      timeout -> []
    end
  end

  test "sends a frame of silence once connected, so the track is live before it speaks", ctx do
    connect(ctx)
    refute_receive {:octoroom_pcm, _}, 50

    assert %{sent: 1, live: true, connected: true, underruns: 0} =
             Outlet.stats(ctx.room_id, "out")

    # Speaking later starts a talkspurt; it isn't live a second time.
    Outlet.play(ctx.room_id, "out", frames(1))
    assert_receive {:outlet_spurt, "out", _}
    assert_receive {:octoroom_pcm, _}
    refute_received {:outlet_live, _, _}
  end

  test "paces queued audio to one frame per 20 ms and reports live once", ctx do
    connect(ctx)
    started = System.monotonic_time(:millisecond)
    Outlet.play(ctx.room_id, "out", frames(10))

    received = collect(100)
    assert length(received) == 10
    assert Enum.all?(received, fn {_, f} -> byte_size(f) == @frame end)

    {last, _} = List.last(received)
    # Ten frames take 180 ms from the first to the last.
    assert last - started >= 170
    refute_received {:outlet_live, _, _}

    assert %{sent: 11, queued_ms: 0, live: true, connected: true, underruns: 1} =
             Outlet.stats(ctx.room_id, "out")
  end

  test "tells the room when talking starts again after a pause", ctx do
    connect(ctx)
    Outlet.play(ctx.room_id, "out", frames(2))
    assert_receive {:outlet_spurt, "out", _}
    assert length(collect(80)) == 2
    refute_received {:outlet_spurt, _, _}

    Outlet.play(ctx.room_id, "out", frames(2))
    assert_receive {:outlet_spurt, "out", pid}
    assert pid == ctx.outlet
    assert length(collect(80)) == 2
    refute_received {:outlet_spurt, _, _}
  end

  test "holds a partial frame until the rest arrives", ctx do
    connect(ctx)
    Outlet.play(ctx.room_id, "out", frames(1) <> :binary.copy(<<2>>, div(@frame, 2)))
    assert [{_, _}] = collect(60)
    Outlet.play(ctx.room_id, "out", :binary.copy(<<2>>, div(@frame, 2)))
    assert [{_, frame}] = collect(60)
    assert frame == :binary.copy(<<2>>, @frame)
  end

  test "flush drops what hasn't played", ctx do
    connect(ctx)
    Outlet.play(ctx.room_id, "out", frames(50))
    assert_receive {:octoroom_pcm, _}
    # 50 frames queued, one or two already sent.
    dropped_ms = Outlet.flush(ctx.room_id, "out")
    assert dropped_ms >= 900 and dropped_ms < 1_000
    assert Outlet.flush(ctx.room_id, "nobody") == nil
    # At most a frame or two already due go out (the test may be slow to flush).
    assert length(collect(100)) <= 2
    assert %{queued_ms: 0} = Outlet.stats(ctx.room_id, "out")
  end

  test "drops audio that comes due before it has a sink", ctx do
    Outlet.play(ctx.room_id, "out", frames(3))
    Process.sleep(80)
    assert %{dropped: 3, sent: 0, live: false} = Outlet.stats(ctx.room_id, "out")
    refute_received {:outlet_live, _, _}

    connect(ctx)
  end

  # The test stands in for the peer connection: `PeerConnection.send_rtp/3`
  # is a cast.
  defp rtp(timeout) do
    receive do
      {:"$gen_cast", {:send_rtp, "track", packet, []}} -> [packet | rtp(timeout)]
    after
      timeout -> []
    end
  end

  test "sends Opus over RTP, with the clock moving on across a pause", ctx do
    send(ctx.outlet, {:octoroom_sink, {:rtp, self(), "track"}})
    # The frame of silence it sends once connected.
    [silence] = rtp(30)
    assert silence.marker

    tone =
      for n <- 0..959, into: <<>> do
        s = round(8000 * :math.sin(n / 10))
        <<s::little-signed-16, s::little-signed-16>>
      end

    Outlet.play(ctx.room_id, "out", :binary.copy(tone, 3))
    [a, b, c] = rtp(100)
    assert a.sequence_number == rem(silence.sequence_number + 1, 65_536)

    assert a.marker and not b.marker and not c.marker
    assert b.sequence_number == rem(a.sequence_number + 1, 65_536)
    assert b.timestamp == rem(a.timestamp + 960, 4_294_967_296)

    decoder = Membrane.Opus.Decoder.Native.create(48_000, 2)
    assert byte_size(Membrane.Opus.Decoder.Native.decode_packet(decoder, a.payload)) == @frame

    # After 200 ms of nothing, the next talkspurt starts ~200 ms later on the
    # RTP clock (48 samples per ms), marked.
    Process.sleep(200)
    Outlet.play(ctx.room_id, "out", tone)
    [d] = rtp(60)
    assert d.marker
    assert d.sequence_number == rem(c.sequence_number + 1, 65_536)
    assert rem(d.timestamp - c.timestamp + 4_294_967_296, 4_294_967_296) >= 200 * 48
  end
end
