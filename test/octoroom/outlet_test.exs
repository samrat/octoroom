defmodule Octoroom.OutletTest do
  use ExUnit.Case, async: true

  alias Octoroom.Outlet

  @frame 3_840

  setup do
    room_id = "outlet-#{System.unique_integer([:positive])}"
    ws_id = Octoroom.Adapter.new_id()
    {:ok, pid} = Outlet.start_link(%{room_id: room_id, name: "out", server: self(), ws_id: ws_id})
    %{room_id: room_id, outlet: pid, ws_id: ws_id}
  end

  # The test plays Cloudflare's socket: it receives `{:octoroom_pcm, frame}`.
  defp connect(ctx), do: send(ctx.outlet, {:octoroom_adapter_socket, :ingest, self()})

  defp frames(n, byte \\ 1), do: :binary.copy(<<byte>>, n * @frame)

  defp collect(timeout) do
    receive do
      {:octoroom_pcm, frame} -> [{System.monotonic_time(:millisecond), frame} | collect(timeout)]
    after
      timeout -> []
    end
  end

  test "registers its adapter id while it runs", ctx do
    assert Octoroom.Adapter.lookup(:ingest, ctx.ws_id) == ctx.outlet
  end

  test "paces queued audio to one frame per 20 ms and reports live once", ctx do
    connect(ctx)
    started = System.monotonic_time(:millisecond)
    Outlet.play(ctx.room_id, "out", frames(10))

    assert_receive {:outlet_live, "out", pid}
    assert pid == ctx.outlet
    received = collect(100)
    assert length(received) == 10
    assert Enum.all?(received, fn {_, f} -> byte_size(f) == @frame end)

    {last, _} = List.last(received)
    # Ten frames take 180 ms from the first to the last.
    assert last - started >= 170
    refute_received {:outlet_live, _, _}

    assert %{sent: 10, queued_ms: 0, live: true, connected: true, underruns: 1} =
             Outlet.stats(ctx.room_id, "out")
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
    Outlet.flush(ctx.room_id, "out")
    # At most a frame or two already due go out (the test may be slow to flush).
    assert length(collect(100)) <= 2
    assert %{queued_ms: 0} = Outlet.stats(ctx.room_id, "out")
  end

  test "drops audio that comes due before Cloudflare dials in", ctx do
    Outlet.play(ctx.room_id, "out", frames(3))
    Process.sleep(80)
    assert %{dropped: 3, sent: 0, live: false} = Outlet.stats(ctx.room_id, "out")
    refute_received {:outlet_live, _, _}

    connect(ctx)
    Outlet.play(ctx.room_id, "out", frames(1))
    assert_receive {:octoroom_pcm, _}
    assert_receive {:outlet_live, "out", _}
  end
end
