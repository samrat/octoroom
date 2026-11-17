defmodule Octoroom.WorkerTest do
  use ExUnit.Case, async: true

  alias Octoroom.Room.Server
  alias Octoroom.Test.{Client, FakeCloudflare}

  @frame :binary.copy(<<1, 0>>, 1_920)

  # Plays back what it hears at once (if it has an output), in 16 kHz mono,
  # and tells the test what happens to it.
  defmodule Echo do
    use Octoroom.Worker, audio: [rate: 16_000, channels: 1]

    @impl true
    def init(%{test: test}, ctx) do
      send(test, {:worker_started, ctx.id, self(), ctx})
      {:ok, {test, ctx.outputs}}
    end

    @impl true
    def handle_audio(_input, _pcm, {_, []} = s), do: {:ok, s}
    def handle_audio(_input, pcm, s), do: {:ok, s, play: {:default, pcm}}

    @impl true
    def handle_info({:octoroom, :inputs, names} = msg, {test, _} = s) do
      send(test, {:worker_info, self(), msg})
      {:ok, s, emit: {:inputs, length(names)}}
    end

    def handle_info(:flush, s), do: {:ok, s, flush: :default}
    def handle_info({:emit, event}, s), do: {:ok, s, emit: event}
    def handle_info(_msg, s), do: {:ok, s}

    @impl true
    def terminate(reason, {test, _}), do: send(test, {:worker_terminated, self(), reason})
  end

  # Everyone with `echo: true` gets a private echo: they hear their own
  # echo, and others' mics, but nobody else's echo.
  defmodule EchoRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}

    @impl true
    def workers(room) do
      for %{meta: %{echo: true}} = p <- room.participants do
        worker("echo:#{p.id}", Octoroom.WorkerTest.Echo,
          inputs: [mic(p)],
          outputs: ["#{p.id}/echo"],
          args: %{test: p.meta.test}
        )
      end
    end

    @impl true
    def subscriptions(listener, room) do
      echo = if listener.meta.echo, do: [track("#{listener.id}/echo")], else: []
      echo ++ for(p <- others(room, listener), do: mic(p))
    end
  end

  # One worker hears every mic, while anyone is in the room.
  defmodule RecRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}

    @impl true
    def workers(%{participants: []}), do: []

    def workers(%{participants: [first | _]} = room) do
      [
        worker("rec", Octoroom.WorkerTest.Echo,
          inputs: Enum.map(room.participants, &mic/1),
          args: %{test: first.meta.test}
        )
      ]
    end
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
        public_ws_url: "wss://example.test/octoroom"
      ]
    }
  end

  defp join(ctx, name, module, meta \\ %{}) do
    meta = Map.merge(%{name: name, echo: false, test: self()}, meta)
    Client.join(name, module, ctx.room_id, meta, ctx.opts)
  end

  defp publish(ctx, client) do
    Server.publish(client.server, client.id, "offer:#{client.name}", %{"mic" => "0"}, :pub)

    assert_receive {:client, name,
                    {:octoroom_signal, :reply, :pub, {:ok, %{sdp: "answer:" <> session}}}}

    assert name == client.name
    FakeCloudflare.mark_live(ctx.fake, session, "#{client.id}/mic")
    Server.connected(client.server, client.id)
    Map.put(client, :session, session)
  end

  defp accept_pull(client, timeout \\ 500) do
    name = client.name
    assert_receive {:client, ^name, {:octoroom_signal, :renegotiate, %{op_id: op}}}, timeout
    Server.answer(client.server, client.id, op, "answer", :ans)
    assert_receive {:client, ^name, {:octoroom_signal, :reply, :ans, {:ok, _}}}
    assert_receive {:client, ^name, {:octoroom_signal, :tracks, %{added: added, removed: []}}}
    added
  end

  defp accept_close(client) do
    name = client.name
    assert_receive {:client, ^name, {:octoroom_signal, :close, %{op_id: op, mids: mids}}}
    Server.close_offer(client.server, client.id, op, "close offer", :close)
    assert_receive {:client, ^name, {:octoroom_signal, :tracks, %{added: [], removed: ^mids}}}
    mids
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end

  defp egress_adapter?(ctx, session, track) do
    ctx.fake
    |> FakeCloudflare.adapters()
    |> Enum.any?(fn {_, a} ->
      a.role == :egress and a.session_id == session and a.track_name == track
    end)
  end

  # Alice joins with an echo, publishes, speaks one frame, and pulls her
  # echo once it's live.
  defp live_echo(ctx) do
    alice = join(ctx, "alice", EchoRoom, %{echo: true})
    worker_id = "echo:#{alice.id}"
    assert_receive {:worker_started, ^worker_id, worker, worker_ctx}
    assert worker_ctx.inputs == ["#{alice.id}/mic"]
    assert worker_ctx.outputs == ["#{alice.id}/echo"]

    # The output's ingest adapter is created at once; the input waits for
    # alice's mic to be live.
    assert_receive {:cloudflare, :new_adapters,
                    [[%{location: "local", trackName: cf_track} = out]]}

    assert out.endpoint =~ ~r"^wss://example.test/octoroom/ingest/"

    alice = publish(ctx, alice)
    session = alice.session
    mic = "#{alice.id}/mic"

    assert_receive {:cloudflare, :new_adapters,
                    [[%{location: "remote", sessionId: ^session, trackName: ^mic} = in_]]}

    assert in_.endpoint =~ ~r"^wss://example.test/octoroom/egress/"
    wait_until(fn -> egress_adapter?(ctx, session, mic) end)

    # Nothing to pull until the echo has sent a frame.
    refute_receive {:client, "alice", {:octoroom_signal, :renegotiate, _}}, 50
    FakeCloudflare.egress(ctx.fake, session, mic, @frame)
    assert_receive {:ingest, ^cf_track, frame}
    assert byte_size(frame) == 3_840

    echo = "#{alice.id}/echo"
    # The server may pull before the fake has processed the first frame;
    # that pull fails as empty and is retried after 0.5 s.
    assert [%{track: ^echo, participant_id: nil, worker_id: ^worker_id}] =
             accept_pull(alice, 1_500)

    %{alice: alice, worker: worker, worker_id: worker_id, echo: echo, cf_track: cf_track}
  end

  test "a private echo: a worker's output goes live and only its owner hears it", ctx do
    Octoroom.subscribe(ctx.room_id)
    %{alice: alice, echo: echo} = live_echo(ctx)
    assert_receive {:octoroom, _, {:output_live, ^echo}}

    state = Octoroom.Room.state(ctx.room_id)
    assert %{^echo => %{status: :live}} = state.outputs
    assert [%{running: true, connected: [mic]}] = state.workers
    assert mic == "#{alice.id}/mic"

    bob = join(ctx, "bob", EchoRoom) |> then(&publish(ctx, &1))
    assert [%{track: alice_mic}] = accept_pull(bob)
    assert alice_mic == "#{alice.id}/mic"
    assert [%{participant_id: bob_id}] = accept_pull(alice)
    assert bob_id == bob.id

    hears =
      for p <- Octoroom.Room.state(ctx.room_id).participants,
          into: %{},
          do: {p.meta.name, p.hears}

    assert hears["alice"] == Enum.sort([echo, "#{bob.id}/mic"])
    assert hears["bob"] == [alice_mic]
  end

  test "turning a worker off stops it and closes its adapters", ctx do
    %{alice: alice, worker: worker} = live_echo(ctx)
    ref = Process.monitor(worker)
    assert map_size(FakeCloudflare.adapters(ctx.fake)) == 2

    :ok = Octoroom.Room.update_meta(ctx.room_id, alice.id, &%{&1 | echo: false})
    assert_receive {:worker_terminated, ^worker, :shutdown}
    assert_receive {:DOWN, ^ref, :process, _, _}
    accept_close(alice)
    wait_until(fn -> FakeCloudflare.adapters(ctx.fake) == %{} end)

    state = Octoroom.Room.state(ctx.room_id)
    assert state.workers == []
    assert state.outputs == %{}
  end

  test "a crashed worker is restarted and its track stays published", ctx do
    Octoroom.subscribe(ctx.room_id)
    %{alice: alice, worker: worker, worker_id: id, cf_track: cf_track} = live_echo(ctx)

    Process.exit(worker, :kill)
    assert_receive {:octoroom, _, {:worker_down, ^id, :killed}}
    assert_receive {:worker_started, ^id, worker2, _}, 1_500
    assert worker2 != worker

    # Same adapters, no renegotiation: the new worker hears and plays
    # through the old inlet and outlet.
    refute_received {:cloudflare, :new_adapters, _}
    refute_received {:cloudflare, :close_adapters, _}
    refute_received {:client, "alice", {:octoroom_signal, :renegotiate, _}}
    refute_received {:client, "alice", {:octoroom_signal, :close, _}}
    FakeCloudflare.egress(ctx.fake, alice.session, "#{alice.id}/mic", @frame)
    assert_receive {:ingest, ^cf_track, _}
  end

  test "flush and emit reach the worker's outlet and the room", ctx do
    Octoroom.subscribe(ctx.room_id)
    %{echo: echo, worker_id: id} = live_echo(ctx)

    :ok = Octoroom.Worker.send(ctx.room_id, id, {:emit, :hello})
    assert_receive {:octoroom, _, {:worker_event, ^id, :hello}}

    Octoroom.Outlet.play(ctx.room_id, echo, :binary.copy(<<0>>, 3_840 * 50))
    :ok = Octoroom.Worker.send(ctx.room_id, id, :flush)
    wait_until(fn -> Octoroom.Outlet.stats(ctx.room_id, echo).queued_ms == 0 end)
    assert Octoroom.Worker.send(ctx.room_id, "nobody", :flush) == {:error, :no_worker}
  end

  test "a worker's inputs follow the room without a restart", ctx do
    Octoroom.subscribe(ctx.room_id)
    alice = join(ctx, "alice", RecRoom) |> then(&publish(ctx, &1))
    assert_receive {:worker_started, "rec", rec, %{inputs: [_]}}
    assert_receive {:cloudflare, :new_adapters, [[%{location: "remote"}]]}

    bob = join(ctx, "bob", RecRoom)
    assert_receive {:worker_info, ^rec, {:octoroom, :inputs, inputs}}
    assert inputs == ["#{alice.id}/mic", "#{bob.id}/mic"]
    assert_receive {:octoroom, _, {:worker_event, "rec", {:inputs, 2}}}

    # Bob's input is connected once his mic is live.
    bob = publish(ctx, bob)
    session = bob.session
    mic = "#{bob.id}/mic"
    assert_receive {:cloudflare, :new_adapters, [[%{sessionId: ^session, trackName: ^mic}]]}
    wait_until(fn -> egress_adapter?(ctx, session, mic) end)

    wait_until(fn ->
      [%{connected: connected}] = Octoroom.Room.state(ctx.room_id).workers
      length(connected) == 2
    end)

    Client.stop(bob)
    assert_receive {:worker_info, ^rec, {:octoroom, :inputs, [_]}}
    assert_receive {:cloudflare, :close_adapters, [[_]]}
    refute_received {:worker_started, _, _, _}

    # The last one out: the room stops, and its adapters are closed.
    room = Octoroom.Room.Server.whereis(ctx.room_id)
    ref = Process.monitor(room)
    Client.stop(alice)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    assert_receive {:worker_terminated, ^rec, :shutdown}
    wait_until(fn -> FakeCloudflare.adapters(ctx.fake) == %{} end)
  end

  test "without a public URL, workers run but get no adapters", ctx do
    opts = Keyword.delete(ctx.opts, :public_ws_url)

    alice =
      Client.join("alice", EchoRoom, ctx.room_id, %{name: "a", echo: true, test: self()}, opts)

    assert_receive {:worker_started, _, _, _}
    refute_receive {:cloudflare, :new_adapters, _}, 50
    assert [%{running: true}] = Octoroom.Room.state(ctx.room_id).workers
    Client.stop(alice)
  end

  defmodule Doomed do
    use Octoroom.Worker

    @impl true
    def init(_args, _ctx), do: {:stop, :nope}

    @impl true
    def handle_audio(_input, _pcm, s), do: {:ok, s}
  end

  defmodule DoomedRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}

    @impl true
    def workers(_room), do: [worker("doomed", Octoroom.WorkerTest.Doomed, [])]
  end

  test "a worker that keeps failing is given up, and the room is told", ctx do
    Octoroom.subscribe(ctx.room_id)
    opts = Keyword.put(ctx.opts, :retry_base_ms, 1)
    Client.join("a", DoomedRoom, ctx.room_id, %{}, opts)

    assert_receive {:octoroom, _, {:error, {:worker, "doomed"}, _reason}}, 1_000
    refute_receive {:octoroom, _, {:error, _, _}}, 100
  end
end
