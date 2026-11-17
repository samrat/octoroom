defmodule Octoroom.InletTest do
  use ExUnit.Case, async: true

  alias Octoroom.Inlet

  # 20 ms of adapter PCM.
  @frame :binary.copy(<<0>>, 3_840)

  setup do
    room_id = "inlet-#{System.unique_integer([:positive])}"
    # The test stands in for the worker the inlet forwards to.
    {:ok, _} = Registry.register(Octoroom.Registry, {:worker, room_id, "w"}, nil)

    start = fn burst_ms ->
      opts = %{
        room_id: room_id,
        worker_id: "w",
        input: "a/mic",
        ws_id: Octoroom.Adapter.new_id(),
        burst_ms: burst_ms
      }

      {:ok, pid} = Inlet.start_link(opts)
      pid
    end

    %{start: start}
  end

  defp push(inlet, n), do: for(_ <- 1..n, do: send(inlet, {:octoroom_pcm, self(), @frame}))

  defp forwarded(timeout \\ 50) do
    receive do
      {:octoroom_input, "a/mic", _} -> 1 + forwarded(timeout)
    after
      timeout -> 0
    end
  end

  test "passes a burst up to the bucket and drops the rest", ctx do
    inlet = ctx.start.(100)
    push(inlet, 12)
    # 100 ms of tokens is five frames (plus whatever refilled meanwhile).
    n = forwarded()
    assert n in 5..6
    assert %{forwarded: ^n, dropped: dropped} = Inlet.stats(inlet)
    assert dropped == 12 - n
  end

  test "refills at real time", ctx do
    inlet = ctx.start.(40)
    push(inlet, 10)
    assert forwarded() in 2..3

    Process.sleep(100)
    push(inlet, 10)
    # 100 ms more, capped at the 40 ms bucket: two frames.
    assert forwarded() == 2
  end

  test "holds a fast stream to real time", ctx do
    inlet = ctx.start.(60)
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
end
