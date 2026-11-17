defmodule Octoroom.RecoveryTest do
  use ExUnit.Case, async: true

  alias Octoroom.Room.Server
  alias Octoroom.Test.{Client, FakeCloudflare}

  @frame :binary.copy(<<1, 0>>, 1_920)

  defmodule GroupRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}
  end

  defmodule Echo do
    use Octoroom.Worker, audio: [rate: 48_000, channels: 2]

    @impl true
    def init(%{test: test}, ctx) do
      send(test, {:worker_started, ctx.id, ctx.resumed})
      {:ok, nil}
    end

    @impl true
    def handle_audio(_input, pcm, s), do: {:ok, s, play: {:default, pcm}}
  end

  # Everyone hears everyone, and their own echo.
  defmodule EchoRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}

    @impl true
    def workers(room) do
      for p <- room.participants do
        worker("echo:#{p.id}", Octoroom.RecoveryTest.Echo,
          inputs: [mic(p)],
          outputs: ["#{p.id}/echo"],
          args: %{test: p.meta.test}
        )
      end
    end

    @impl true
    def subscriptions(listener, room),
      do: [track("#{listener.id}/echo") | for(p <- others(room, listener), do: mic(p))]
  end

  setup do
    {:ok, fake} = FakeCloudflare.start_link(self())
    room_id = "room-#{System.unique_integer([:positive])}"

    %{
      fake: fake,
      room_id: room_id,
      opts: [
        cloudflare: FakeCloudflare.config(fake),
        signal_timeout: 1_000,
        grace_ms: 300,
        peer_media: Octoroom.Test.FakePeerMedia
      ]
    }
  end

  defp join(ctx, name, module \\ GroupRoom) do
    Client.join(name, module, ctx.room_id, %{name: name, test: self()}, ctx.opts)
  end

  # Publishes, and keeps the resume data the room sends once the session
  # exists.
  defp publish(ctx, client) do
    Server.publish(client.server, client.id, "offer:#{client.name}", %{"mic" => "0"}, :pub)
    name = client.name

    assert_receive {:client, ^name,
                    {:octoroom_signal, :reply, :pub, {:ok, %{sdp: "answer:" <> session}}}}

    assert_receive {:client, ^name, {:octoroom_signal, :resume, %{session_id: ^session} = data}}
    FakeCloudflare.mark_live(ctx.fake, session, "#{client.id}/mic")
    Server.connected(client.server, client.id)
    client |> Map.put(:session, session) |> Map.put(:resume, data)
  end

  defp accept_pull(client, timeout \\ 500) do
    name = client.name

    assert_receive {:client, ^name, {:octoroom_signal, :renegotiate, %{op_id: op}}}, timeout
    Server.answer(client.server, client.id, op, "answer", :ans)
    assert_receive {:client, ^name, {:octoroom_signal, :reply, :ans, {:ok, _}}}
    assert_receive {:client, ^name, {:octoroom_signal, :tracks, %{added: added, removed: []}}}
    added
  end

  defp accept_close(client, timeout \\ 500) do
    name = client.name
    assert_receive {:client, ^name, {:octoroom_signal, :close, %{op_id: op, mids: mids}}}, timeout
    Server.close_offer(client.server, client.id, op, "close offer", :close)
    assert_receive {:client, ^name, {:octoroom_signal, :reply, :close, {:ok, _}}}
    assert_receive {:client, ^name, {:octoroom_signal, :tracks, %{added: [], removed: ^mids}}}
    mids
  end

  defp hears(ctx) do
    case Octoroom.Room.state(ctx.room_id) do
      %{participants: ps} -> Map.new(ps, &{&1.id, &1.hears})
      error -> error
    end
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && eventually(fun, tries - 1)
    end
  end

  # Two people who hear each other.
  defp call(ctx, module \\ GroupRoom) do
    alice = join(ctx, "alice", module) |> then(&publish(ctx, &1))
    bob = join(ctx, "bob", module) |> then(&publish(ctx, &1))
    if module == GroupRoom, do: accept_pull(alice) && accept_pull(bob)
    {alice, bob}
  end

  # A node restart, as far as the room is concerned: its processes die
  # without running terminate, and its record stays in the store.
  defp kill_room(ctx) do
    flush_cloudflare()
    server = Server.whereis(ctx.room_id)
    ref = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    eventually(fn -> Server.whereis(ctx.room_id) == nil end)
  end

  defp flush_cloudflare do
    receive do
      {:cloudflare, _, _} -> flush_cloudflare()
    after
      0 -> :ok
    end
  end

  describe "a dropped connection" do
    test "coming back within the grace period changes nothing at Cloudflare", ctx do
      {alice, bob} = call(ctx)
      Octoroom.subscribe(ctx.room_id)

      Client.drop(alice)
      assert_receive {:octoroom, _, {:disconnected, %{id: id}}} when id == alice.id
      refute_receive {:client, "bob", {:octoroom_signal, :close, _}}, 100
      assert hears(ctx)[alice.id] == ["#{bob.id}/mic"]

      alice2 = Client.resume("alice", GroupRoom, ctx.room_id, alice.resume, ctx.opts)
      assert alice2.id == alice.id
      assert alice2.reply.resumed

      assert_receive {:client, "alice", {:octoroom_signal, :tracks, %{reset: true, added: added}}}
      assert [%{track: track, participant_id: pid}] = added
      assert track == "#{bob.id}/mic" and pid == bob.id

      refute_receive {:cloudflare, :session_state, _}, 50
      refute_received {:client, _, {:octoroom_signal, :renegotiate, _}}
      refute_received {:octoroom, _, {:left, _}}
    end

    test "a channel shut down with the node isn't a leave either", ctx do
      {alice, _bob} = call(ctx)
      Octoroom.subscribe(ctx.room_id)
      Process.exit(alice.pid, :shutdown)
      assert_receive {:octoroom, _, {:disconnected, %{id: id}}} when id == alice.id
      refute_receive {:octoroom, _, {:left, _}}, 100
    end

    test "nor is Phoenix draining sockets; leaving is", ctx do
      {alice, bob} = call(ctx)
      Octoroom.subscribe(ctx.room_id)
      Process.exit(alice.pid, {:shutdown, :restart})
      assert_receive {:octoroom, _, {:disconnected, _}}
      Process.exit(bob.pid, {:shutdown, :left})
      assert_receive {:octoroom, _, {:left, %{id: id}}} when id == bob.id
    end

    test "not coming back is a leave", ctx do
      {alice, bob} = call(ctx)
      Client.drop(alice)
      accept_close(bob, 1_000)
      assert Map.keys(hears(ctx)) == [bob.id]
    end

    test "a request it missed is sent again when it comes back", ctx do
      ctx = %{ctx | opts: Keyword.put(ctx.opts, :grace_ms, 5_000)}
      alice = join(ctx, "alice") |> then(&publish(ctx, &1))
      Client.drop(alice)
      Process.sleep(20)
      bob = join(ctx, "bob") |> then(&publish(ctx, &1))
      accept_pull(bob)

      # Alice's pull of bob is waiting on her answer, past the signal timeout.
      Process.sleep(1_100)
      alice = Client.resume("alice", GroupRoom, ctx.room_id, alice.resume, ctx.opts)
      assert_receive {:client, "alice", {:octoroom_signal, :tracks, %{reset: true, added: []}}}
      assert [%{participant_id: pid}] = accept_pull(alice)
      assert pid == bob.id
    end
  end

  describe "a restarted room" do
    test "adopts sessions as they are: nobody renegotiates", ctx do
      {alice, bob} = call(ctx)
      kill_room(ctx)

      alice2 = Client.resume("alice", GroupRoom, ctx.room_id, alice.resume, ctx.opts)
      assert alice2.reply.resumed and alice2.id == alice.id
      assert_receive {:cloudflare, :session_state, [s]} when s == alice.session

      # Bob hasn't come back yet, but alice keeps hearing him.
      assert_receive {:client, "alice", {:octoroom_signal, :tracks, %{reset: true, added: added}}}
      assert [%{track: track, mid: "1", participant_id: bob_id}] = added
      assert track == "#{bob.id}/mic" and bob_id == bob.id

      bob2 = Client.resume("bob", GroupRoom, ctx.room_id, bob.resume, ctx.opts)
      assert bob2.id == bob.id
      assert_receive {:client, "bob", {:octoroom_signal, :tracks, %{reset: true, added: [_]}}}

      eventually(fn ->
        hears(ctx) == %{alice.id => ["#{bob.id}/mic"], bob.id => ["#{alice.id}/mic"]}
      end)

      # Past the grace period, still nothing to do.
      refute_receive {:client, _, {:octoroom_signal, :close, _}}, 400
      refute_received {:client, _, {:octoroom_signal, :renegotiate, _}}

      refute_received {:cloudflare, :pull_tracks, _}
    end

    test "after the grace period, those who didn't come back have left", ctx do
      {alice, bob} = call(ctx)
      kill_room(ctx)

      alice = Client.resume("alice", GroupRoom, ctx.room_id, alice.resume, ctx.opts)
      assert_receive {:client, "alice", {:octoroom_signal, :tracks, %{reset: true}}}
      refute_receive {:client, "alice", {:octoroom_signal, :close, _}}, 150

      assert accept_close(alice, 500) == ["1"]
      assert hears(ctx) == %{alice.id => []}
      _ = bob
    end

    test "keeps the room's assigns and tells new workers they're resumed", ctx do
      alice = join(ctx, "alice", EchoRoom)
      assert_receive {:worker_started, _, nil}
      :ok = Octoroom.Room.assign(ctx.room_id, :topic, "standup")
      alice = publish(ctx, alice)
      kill_room(ctx)

      Client.resume("alice", EchoRoom, ctx.room_id, alice.resume, ctx.opts)
      assert_receive {:worker_started, "echo:" <> _, %{gone_ms: gone}}
      assert gone >= 0
      assert Octoroom.Room.state(ctx.room_id).assigns == %{topic: "standup"}
    end

    test "re-pulls worker outputs from their new sessions", ctx do
      alice = join(ctx, "alice", EchoRoom) |> then(&publish(ctx, &1))
      mic = "#{alice.id}/mic"
      echo = "#{alice.id}/echo"

      # Alice's echo goes live and she pulls it.
      eventually(fn ->
        FakeCloudflare.egress(ctx.fake, alice.session, mic, @frame)
        Octoroom.Room.state(ctx.room_id).outputs[echo][:status] == :live
      end)

      assert [%{track: ^echo}] = accept_pull(alice)
      kill_room(ctx)

      session = alice.session
      alice = Client.resume("alice", EchoRoom, ctx.room_id, alice.resume, ctx.opts)
      assert_receive {:client, "alice", {:octoroom_signal, :tracks, %{reset: true, added: [_]}}}

      # The old pull is of a session that died with the node.
      assert accept_close(alice) == ["1"]

      eventually(fn ->
        FakeCloudflare.egress(ctx.fake, session, mic, @frame)
        Octoroom.Room.state(ctx.room_id).outputs[echo][:status] == :live
      end)

      assert [%{track: ^echo, mid: "2"}] = accept_pull(alice)
    end

    test "a session whose peer connection closed publishes again", ctx do
      {alice, _bob} = call(ctx)
      kill_room(ctx)
      FakeCloudflare.disconnect(ctx.fake, alice.session)

      alice2 = Client.resume("alice", GroupRoom, ctx.room_id, alice.resume, ctx.opts)
      assert alice2.id == alice.id
      assert_receive {:client, "alice", {:octoroom_signal, :republish, %{reason: :disconnected}}}
      assert_receive {:client, "alice", {:octoroom_signal, :resume, %{session_id: nil}}}

      Server.publish(alice2.server, alice2.id, "offer", %{"mic" => "0"}, :pub)
      assert_receive {:client, "alice", {:octoroom_signal, :reply, :pub, {:ok, _}}}
    end

    test "a participant that never published starts over", ctx do
      alice = join(ctx, "alice")
      kill_room(ctx)

      alice2 = Client.resume("alice", GroupRoom, ctx.room_id, alice.reply.resume, ctx.opts)
      assert alice2.id == alice.id
      refute alice2.reply.resumed
      refute_received {:cloudflare, :session_state, _}
    end
  end

  test "telemetry tells a recovery apart from a fresh start", ctx do
    test = self()
    room_id = ctx.room_id
    handler = "recovery-#{room_id}"

    :telemetry.attach_many(
      handler,
      Octoroom.Telemetry.events(),
      fn event, measurements, meta, _ ->
        if meta[:room_id] == room_id, do: send(test, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {alice, _bob} = call(ctx)
    assert_received {:telemetry, [:octoroom, :room, :start], _, %{recovered: false}}
    assert_received {:telemetry, [:octoroom, :participant, :join], _, _}
    assert_received {:telemetry, [:octoroom, :pull, :stop], %{duration_ms: _, tracks: 1}, _}

    kill_room(ctx)
    Client.resume("alice", GroupRoom, ctx.room_id, alice.resume, ctx.opts)
    assert_receive {:telemetry, [:octoroom, :room, :start], _, %{recovered: true}}
    assert_receive {:telemetry, [:octoroom, :participant, :resume], _, %{kind: :adopt}}
    assert_receive {:telemetry, [:octoroom, :room, :recovered], %{ghosts: 1}, _}, 1_000
  end
end
