defmodule Octoroom.PeerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Octoroom.Peer
  alias Octoroom.Test.{FakeCloudflare, FakePeerMedia}

  # A peer connection that negotiates but never connects, as when the host
  # blocks outbound UDP.
  defmodule Stuck do
    @behaviour Octoroom.Peer.Media
    defdelegate init(opts), to: FakePeerMedia
    defdelegate session_created(state, session), to: FakePeerMedia
    defdelegate offer_sendonly(state, n), to: FakePeerMedia
    def apply_answer(state, _sdp), do: {:ok, state}
    defdelegate answer_offer(state, sdp), to: FakePeerMedia
    def renegotiated(state), do: state
    defdelegate stop_and_offer(state, mids), to: FakePeerMedia
    def handle_info(_message, state), do: {:ignore, state}
    def close(_state), do: :ok
  end

  setup do
    {:ok, fake} = FakeCloudflare.start_link(self())
    %{cf: FakeCloudflare.config(fake)}
  end

  defp start(ctx, media, opts \\ %{}) do
    opts =
      Map.merge(%{worker_id: "w", server: self(), cloudflare: ctx.cf, media: media}, opts)

    {:ok, peer} = Peer.start_link(opts)
    Process.unlink(peer)
    peer
  end

  test "batches pushes that queue up behind another operation", ctx do
    peer = start(ctx, FakePeerMedia)
    for name <- ~w(a b c), do: Peer.push(peer, name, "out-#{name}", self())

    # The first push waits for the session; the other two then go together.
    assert_receive {:cloudflare, :push_tracks, [session, _, [%{track_name: "out-a"}]]}
    assert_receive {:cloudflare, :push_tracks, [^session, _, [_, _] = tracks]}
    assert Enum.map(tracks, & &1.track_name) == ["out-b", "out-c"]

    for name <- ~w(a b c),
        do: assert_receive({:peer_result, "w", ^peer, {:pushed, ^name, ^session}})

    # Each outlet gets its sink once the connection is up.
    for _ <- 1..3, do: assert_receive({:octoroom_sink, {:pcm, _}})
  end

  test "an input closed before its pull completes is closed right after", ctx do
    peer = start(ctx, FakePeerMedia)
    source = %{session_id: "elsewhere", track_name: "mic"}
    Peer.pull(peer, "mic", source, self())
    Peer.close(peer, {:input, "mic"})

    # Nothing was pulled (the fake has no such live track), so nothing to close.
    assert_receive {:peer_result, "w", ^peer, {:pull_failed, "mic", "empty_track_error"}}
    refute_receive {:cloudflare, :close_tracks, _}, 50
  end

  test "stops with a clear error when the connection doesn't come up", ctx do
    log =
      capture_log(fn ->
        peer = start(ctx, Stuck, %{connect_timeout: 50})
        ref = Process.monitor(peer)
        Peer.push(peer, "a", "out-a", self())
        assert_receive {:DOWN, ^ref, :process, ^peer, {:shutdown, :connect_timeout}}, 1_000
        refute_received {:octoroom_sink, _}
      end)

    assert log =~ "outbound UDP"
  end
end
