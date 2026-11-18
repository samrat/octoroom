defmodule Octoroom.RoomTest do
  use ExUnit.Case, async: true

  alias Octoroom.Room.Server
  alias Octoroom.Test.{Client, FakeCloudflare}

  defmodule GroupRoom do
    use Octoroom.Room

    @impl true
    def join(%{"name" => name}, _socket), do: {:ok, %{name: name}}
  end

  # Only listeners with `deaf: false` hear anyone, and quietly.
  defmodule QuietRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{deaf: false}}

    @impl true
    def subscriptions(%{meta: %{deaf: true}}, _room), do: []

    def subscriptions(listener, room),
      do: for(p <- others(room, listener), do: mic(p) |> gain(0.5))
  end

  defmodule Idle do
    use Octoroom.Worker

    @impl true
    def init(test, _ctx) do
      send(test, {:idle_started, self()})
      {:ok, test}
    end

    @impl true
    def handle_audio(_input, _pcm, test), do: {:ok, test}
  end

  # Policies that fail on demand: a listener's `policy` metadata, and the
  # room's `workers` assign or id prefix.
  defmodule PolicyRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}

    @impl true
    def mount("raise-" <> _), do: raise("no assigns")
    def mount("bad-" <> _), do: :ok
    def mount(_room_id), do: {:ok, %{}}

    @impl true
    def workers(%{assigns: %{workers: :raise}}), do: raise("no workers today")
    def workers(%{assigns: %{workers: :bad}}), do: [%{id: "idle"}]

    def workers(%{assigns: %{test: test}}),
      do: [worker("idle", Octoroom.RoomTest.Idle, args: test)]

    def workers(_room), do: []

    @impl true
    def subscriptions(%{meta: %{policy: :raise}} = listener, _room), do: [listener.meta.lang]
    def subscriptions(%{meta: %{policy: :throw}}, _room), do: throw(:nope)
    def subscriptions(%{meta: %{policy: :bad}}, _room), do: :everyone
    def subscriptions(listener, room), do: default_subscriptions(listener, room)
  end

  setup do
    {:ok, fake} = FakeCloudflare.start_link(self())
    room_id = "room-#{System.unique_integer([:positive])}"

    %{
      fake: fake,
      room_id: room_id,
      opts: [cloudflare: FakeCloudflare.config(fake), signal_timeout: 500]
    }
  end

  defp join(ctx, name, module \\ GroupRoom, meta \\ nil) do
    Client.join(name, module, ctx.room_id, meta || %{name: name}, ctx.opts)
  end

  # Publishes the client's mic, then reports it connected once Cloudflare has
  # its first packet.
  defp publish(ctx, client) do
    Server.publish(client.server, client.id, "offer:#{client.name}", %{"mic" => "0"}, :pub)

    assert_receive {:client, name,
                    {:octoroom_signal, :reply, :pub, {:ok, %{sdp: "answer:" <> session}}}}

    assert name == client.name
    FakeCloudflare.mark_live(ctx.fake, session, "#{client.id}/mic")
    Server.connected(client.server, client.id)
    Map.put(client, :session, session)
  end

  # Plays the browser's side of a pull: answers Cloudflare's offer.
  defp accept_pull(client, timeout \\ 100) do
    name = client.name

    assert_receive {:client, ^name,
                    {:octoroom_signal, :renegotiate, %{op_id: op, sdp: "offer-" <> _}}},
                   timeout

    Server.answer(client.server, client.id, op, "answer from #{name}", :ans)
    assert_receive {:client, ^name, {:octoroom_signal, :reply, :ans, {:ok, _}}}
    assert_receive {:client, ^name, {:octoroom_signal, :tracks, %{added: added, removed: []}}}
    added
  end

  defp accept_close(client) do
    name = client.name
    assert_receive {:client, ^name, {:octoroom_signal, :close, %{op_id: op, mids: mids}}}
    Server.close_offer(client.server, client.id, op, "close offer", :close)
    assert_receive {:client, ^name, {:octoroom_signal, :reply, :close, {:ok, %{sdp: _}}}}
    assert_receive {:client, ^name, {:octoroom_signal, :tracks, %{added: [], removed: ^mids}}}
    mids
  end

  defp hears(ctx) do
    for p <- Octoroom.Room.state(ctx.room_id).participants, into: %{}, do: {p.meta.name, p.hears}
  end

  test "two participants hear each other, and leave and rejoin works", ctx do
    Octoroom.subscribe(ctx.room_id, scope: :room)
    alice = join(ctx, "alice") |> then(&publish(ctx, &1))
    refute_receive {:client, "alice", {:octoroom_signal, :renegotiate, _}}, 50

    bob = join(ctx, "bob")
    assert_receive {:client, "alice", {:octoroom_signal, :room_event, {:joined, %{id: bob_id}}}}
    assert bob_id == bob.id
    assert [%{id: _}, %{id: ^bob_id}] = bob.reply.participants

    # Bob's mic isn't live yet, so nobody pulls it, and bob can't receive.
    refute_receive {:client, _, {:octoroom_signal, :renegotiate, _}}, 50

    bob = publish(ctx, bob)
    assert [%{track: track, participant_id: ^bob_id, gain: 1.0, mid: "1"}] = accept_pull(alice)
    assert track == "#{bob.id}/mic"
    assert [%{participant_id: alice_id}] = accept_pull(bob)
    assert alice_id == alice.id

    assert_receive {:cloudflare, :pull_tracks,
                    [session, [%{session_id: bob_session, track_name: bob_mic}]]}
                   when session == alice.session

    assert bob_session == bob.session
    assert bob_mic == "#{bob.id}/mic"
    assert hears(ctx) == %{"alice" => ["#{bob.id}/mic"], "bob" => ["#{alice.id}/mic"]}
    assert_receive {:octoroom, _, {:subscriptions, ^alice_id, [_]}}

    # Bob leaves: alice closes her pull of his mic.
    Client.stop(bob)
    assert_receive {:octoroom, _, {:left, %{id: ^bob_id}}}
    assert ["1"] = accept_close(alice)
    assert_receive {:cloudflare, :close_tracks, [_, ["1"], "close offer"]}
    assert hears(ctx) == %{"alice" => []}
    assert FakeCloudflare.tracks(ctx.fake, alice.session) |> Map.keys() == ["0"]

    # Bob comes back as a new participant.
    bob2 = join(ctx, "bob") |> then(&publish(ctx, &1))
    assert [%{participant_id: id}] = accept_pull(alice)
    assert id == bob2.id
    accept_pull(bob2)
    assert hears(ctx) == %{"alice" => ["#{bob2.id}/mic"], "bob" => ["#{alice.id}/mic"]}
  end

  test "a participant-scoped subscriber gets what that participant's client gets", ctx do
    # Before the room exists, and for an id that never joins: nothing arrives.
    Octoroom.subscribe(ctx.room_id, scope: {:participant, "nobody"})

    alice = join(ctx, "alice") |> then(&publish(ctx, &1))
    alice_id = alice.id
    Octoroom.subscribe(ctx.room_id, scope: {:participant, alice_id})

    bob = join(ctx, "bob") |> then(&publish(ctx, &1))
    bob_id = bob.id
    assert_receive {:octoroom, _, {:joined, %{id: ^bob_id}}}
    assert_receive {:octoroom, _, {:published, %{id: ^bob_id}}}
    accept_pull(alice)
    accept_pull(bob)

    # Room-wide events stay with `scope: :room` subscribers.
    refute_receive {:octoroom, _, {:subscriptions, _, _}}, 50

    Client.stop(bob)
    assert_receive {:octoroom, _, {:left, %{id: ^bob_id}}}
    accept_close(alice)

    # One message per event: the "nobody" subscription got none of them.
    refute_receive {:octoroom, _, {:joined, _}}, 50
    refute_receive {:octoroom, _, {:left, _}}, 50
  end

  test "subscribe/2 refuses a missing or unknown scope", ctx do
    assert_raise ArgumentError, fn -> Octoroom.subscribe(ctx.room_id, []) end
    assert_raise ArgumentError, fn -> Octoroom.subscribe(ctx.room_id, scope: :all) end

    assert_raise ArgumentError, fn ->
      Octoroom.subscribe(ctx.room_id, scope: {:participant, 1})
    end
  end

  test "telemetry times each step of a join", ctx do
    test = self()
    room_id = ctx.room_id
    handler = "join-#{room_id}"

    :telemetry.attach_many(
      handler,
      [[:octoroom, :participant, :connected], [:octoroom, :participant, :first_pull]],
      fn event, measurements, meta, _ ->
        if meta.room_id == room_id, do: send(test, {:telemetry, event, measurements, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    alice = join(ctx, "alice")
    Server.publish(alice.server, alice.id, "offer:alice", %{"mic" => "0"}, :pub)

    assert_receive {:client, "alice",
                    {:octoroom_signal, :reply, :pub, {:ok, %{sdp: "answer:" <> session}}}}

    FakeCloudflare.mark_live(ctx.fake, session, "#{alice.id}/mic")
    Server.connected(alice.server, alice.id, %{media_ms: 600, ice_ms: 2001, ice_timed_out: true})

    alice_id = alice.id
    assert_receive {:telemetry, [:octoroom, :participant, :connected], m, %{id: ^alice_id} = meta}
    assert %{client_media_ms: 600, client_ice_ms: 2001} = m

    for key <- [:duration_ms, :before_publish_ms, :publish_ms, :connect_ms],
        do: assert(is_integer(m[key]) and m[key] >= 0, "#{key}: #{inspect(m[key])}")

    assert m.duration_ms == m.before_publish_ms + m.publish_ms + m.connect_ms
    assert meta.ice_timed_out and meta.sources == ["mic"]

    # Reported once: a later `connected` (after publishing more) isn't a join.
    Server.connected(alice.server, alice.id)
    refute_receive {:telemetry, [:octoroom, :participant, :connected], _, _}, 50

    # Alone, she hears nobody; once bob is live, she does.
    refute_received {:telemetry, [:octoroom, :participant, :first_pull], _, _}
    bob = join(ctx, "bob") |> then(&publish(ctx, &1))
    accept_pull(alice)
    accept_pull(bob)

    assert_receive {:telemetry, [:octoroom, :participant, :first_pull], first, %{id: ^alice_id}}
    assert %{tracks: 1, since_connected_ms: since} = first
    assert first.duration_ms >= since

    # Bob's join was timed by the server alone: his client sent no timings.
    bob_id = bob.id
    assert_received {:telemetry, [:octoroom, :participant, :connected], bob_m, %{id: ^bob_id}}
    refute Map.has_key?(bob_m, :client_ice_ms)
    assert_received {:telemetry, [:octoroom, :participant, :first_pull], _, %{id: ^bob_id}}
  end

  test "the default logger logs a line per step of a join" do
    meta = %{room_id: "r", id: "p", sources: ["mic"], ice_timed_out: true}

    client = %{
      duration_ms: 3412,
      before_publish_ms: 2700,
      publish_ms: 410,
      connect_ms: 302,
      client_join_ms: 80,
      client_media_ms: 600,
      client_ice_ms: 2001,
      client_publish_ms: 430,
      client_connect_ms: 190
    }

    assert Octoroom.Telemetry.format([:octoroom, :participant, :connected], client, meta) ==
             "Octoroom r p connected in 3412 ms: join 80, media 600, ice 2001 (timed out), " <>
               "publish 430, connect 190"

    server = Map.take(client, [:duration_ms, :before_publish_ms, :publish_ms, :connect_ms])

    assert Octoroom.Telemetry.format([:octoroom, :participant, :connected], server, meta) ==
             "Octoroom r p connected in 3412 ms: before publish 2700, publish 410, connect 302"
  end

  test "pulls for several tracks go in one call", ctx do
    alice = join(ctx, "alice") |> then(&publish(ctx, &1))
    bob = join(ctx, "bob") |> then(&publish(ctx, &1))
    accept_pull(alice)
    accept_pull(bob)
    carol = join(ctx, "carol") |> then(&publish(ctx, &1))

    assert [_, _] = accept_pull(carol)
    accept_pull(alice)
    accept_pull(bob)
    assert hears(ctx)["carol"] == Enum.sort(["#{alice.id}/mic", "#{bob.id}/mic"])
  end

  test "an empty track is retried until it has packets", ctx do
    alice = join(ctx, "alice") |> then(&publish(ctx, &1))
    bob = join(ctx, "bob")
    Server.publish(bob.server, bob.id, "offer", %{"mic" => "0"}, :pub)

    assert_receive {:client, "bob",
                    {:octoroom_signal, :reply, :pub, {:ok, %{sdp: "answer:" <> session}}}}

    # Bob says he's connected before Cloudflare has a packet.
    Server.connected(bob.server, bob.id)
    assert_receive {:cloudflare, :pull_tracks, [s, _]} when s == alice.session
    # Bob can already hear alice.
    accept_pull(bob)
    refute_receive {:client, "alice", {:octoroom_signal, :renegotiate, _}}, 100

    FakeCloudflare.mark_live(ctx.fake, session, "#{bob.id}/mic")
    accept_pull(alice, 1_500)
  end

  test "a policy picks tracks and gains, and a metadata change re-runs it", ctx do
    a =
      Client.join("a", QuietRoom, ctx.room_id, %{name: "a", deaf: false}, ctx.opts)
      |> then(&publish(ctx, &1))

    b =
      Client.join("b", QuietRoom, ctx.room_id, %{name: "b", deaf: true}, ctx.opts)
      |> then(&publish(ctx, &1))

    assert [%{gain: 0.5}] = accept_pull(a)
    refute_receive {:client, "b", {:octoroom_signal, :renegotiate, _}}, 50

    :ok = Octoroom.Room.update_meta(ctx.room_id, b.id, &%{&1 | deaf: false})
    accept_pull(b)
    :ok = Octoroom.Room.update_meta(ctx.room_id, a.id, &%{&1 | deaf: true})
    accept_close(a)
    assert hears(ctx) == %{"a" => [], "b" => ["#{a.id}/mic"]}
  end

  test "a participant that doesn't answer is removed", ctx do
    Octoroom.subscribe(ctx.room_id, scope: :room)
    alice = join(ctx, "alice") |> then(&publish(ctx, &1))
    _bob = join(ctx, "bob") |> then(&publish(ctx, &1))
    alice_id = alice.id

    assert_receive {:client, "alice", {:octoroom_signal, :renegotiate, _}}
    assert_receive {:client, "alice", {:octoroom_signal, :kick, :signaling_timeout}}, 1_000
    assert_receive {:octoroom, _, {:left, %{id: ^alice_id}}}
  end

  test "a failed publish is reported", ctx do
    FakeCloudflare.fail_next(ctx.fake, :new_session, :boom)
    alice = join(ctx, "alice")
    Server.publish(alice.server, alice.id, "offer", %{"mic" => "0"}, :pub)
    assert_receive {:client, "alice", {:octoroom_signal, :reply, :pub, {:error, :boom}}}
  end

  test "the room stops when its last participant leaves", ctx do
    alice = join(ctx, "alice")
    ref = Process.monitor(alice.server)
    Client.stop(alice)
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    # The registry drops the name asynchronously.
    Process.sleep(20)
    assert Server.whereis(ctx.room_id) == nil
  end

  describe "bad input" do
    @describetag :capture_log

    test "malformed client payloads are refused, and the room stays up", ctx do
      alice = join(ctx, "alice")
      ref = Process.monitor(alice.server)

      Server.publish(alice.server, alice.id, "offer", "notamap", :p1)
      Server.publish(alice.server, alice.id, "offer", %{"mic" => 0}, :p2)
      Server.publish(alice.server, alice.id, nil, %{"mic" => "0"}, :p3)

      for tag <- [:p1, :p2, :p3],
          do:
            assert_receive(
              {:client, "alice", {:octoroom_signal, :reply, ^tag, {:error, :bad_payload}}}
            )

      # Nothing was started: a well-formed publish still works.
      alice = publish(ctx, alice)

      Server.publish_tracks(alice.server, alice.id, [%{}], :t1)
      Server.publish_tracks(alice.server, alice.id, "camera", :t2)
      Server.unpublish(alice.server, alice.id, %{}, :u)
      Server.answer(alice.server, alice.id, "op", 42, :a)
      Server.close_offer(alice.server, alice.id, %{}, "offer", :c)

      for tag <- [:t1, :t2, :u, :a, :c],
          do:
            assert_receive(
              {:client, "alice", {:octoroom_signal, :reply, ^tag, {:error, :bad_payload}}}
            )

      # `mute` has no reply; it's dropped.
      Server.mute(alice.server, alice.id, %{}, true)

      refute_receive {:DOWN, ^ref, _, _, _}, 50
      assert [%{media: :live, mic: :live}] = Octoroom.Room.state(ctx.room_id).participants
    end

    test "a push offer with malformed mids is refused, and a good one still goes through", ctx do
      alice = join(ctx, "alice") |> then(&publish(ctx, &1))
      ref = Process.monitor(alice.server)
      Server.publish_tracks(alice.server, alice.id, ["camera"], :cam)
      assert_receive {:client, "alice", {:octoroom_signal, :push, %{op_id: op}}}

      Server.push_offer(alice.server, alice.id, op, "camera offer", "notamap", :o1)
      assert_receive {:client, "alice", {:octoroom_signal, :reply, :o1, {:error, :bad_payload}}}

      Server.push_offer(alice.server, alice.id, op, "camera offer", %{"camera" => "1"}, :o2)
      assert_receive {:client, "alice", {:octoroom_signal, :reply, :o2, {:ok, %{sdp: _}}}}
      assert_receive {:client, "alice", {:octoroom_signal, :reply, :cam, {:ok, %{}}}}
      refute_receive {:DOWN, ^ref, _, _, _}, 50
    end

    test "subscriptions/2 failing for one listener keeps what it holds, and others reconcile",
         ctx do
      Octoroom.subscribe(ctx.room_id, scope: :room)
      alice = join(ctx, "alice", PolicyRoom) |> then(&publish(ctx, &1))

      bob =
        join(ctx, "bob", PolicyRoom, %{name: "bob", policy: :raise}) |> then(&publish(ctx, &1))

      ref = Process.monitor(bob.server)
      bob_id = bob.id

      assert_receive {:octoroom, _, {:error, {:policy, :subscriptions}, %KeyError{key: :lang}}}
      assert [%{track: track}] = accept_pull(alice)
      assert track == "#{bob_id}/mic"
      refute_receive {:client, "bob", {:octoroom_signal, :renegotiate, _}}, 50

      # Reported when it starts failing, not on every reconcile...
      :ok = Octoroom.Room.refresh(ctx.room_id)
      refute_receive {:octoroom, _, {:error, _, _}}, 50

      # ...and again when it fails differently.
      update_policy(ctx, bob, :bad)
      assert_receive {:octoroom, _, {:error, {:policy, :subscriptions}, {:bad_return, :everyone}}}

      # Fixed: bob hears alice.
      update_policy(ctx, bob, nil)
      accept_pull(bob)

      # Broken while holding alice: bob keeps her, and doesn't pull carol.
      update_policy(ctx, bob, :throw)
      assert_receive {:octoroom, _, {:error, {:policy, :subscriptions}, {:throw, :nope}}}
      carol = join(ctx, "carol", PolicyRoom) |> then(&publish(ctx, &1))
      accept_pull(alice)
      assert [_, _] = accept_pull(carol)

      refute_receive {:client, "bob", {:octoroom_signal, :renegotiate, _}}, 50
      refute_received {:client, "bob", {:octoroom_signal, :close, _}}

      assert hears(ctx)["bob"] == ["#{alice.id}/mic"]

      # A track that leaves the directory still closes.
      Client.stop(alice)
      accept_close(bob)
      accept_close(carol)
      assert hears(ctx)["bob"] == []

      refute_receive {:DOWN, ^ref, _, _, _}, 50
    end

    test "workers/1 failing keeps the running workers, and listeners still reconcile", ctx do
      Octoroom.subscribe(ctx.room_id, scope: :room)
      test = self()
      room_id = ctx.room_id
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:octoroom, :policy, :error],
        fn _, _, %{room_id: ^room_id} = meta, _ -> send(test, {:telemetry, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      alice = join(ctx, "alice", PolicyRoom) |> then(&publish(ctx, &1))
      ref = Process.monitor(alice.server)
      :ok = Octoroom.Room.assign(ctx.room_id, :test, self())
      assert_receive {:idle_started, worker}

      :ok = Octoroom.Room.assign(ctx.room_id, :workers, :raise)
      error = %RuntimeError{message: "no workers today"}
      assert_receive {:octoroom, _, {:error, {:policy, :workers}, ^error}}
      assert_receive {:telemetry, %{callback: :workers, participant_id: nil, reason: ^error}}

      bob = join(ctx, "bob", PolicyRoom) |> then(&publish(ctx, &1))
      accept_pull(alice)
      accept_pull(bob)

      :ok = Octoroom.Room.assign(ctx.room_id, :workers, :bad)
      assert_receive {:octoroom, _, {:error, {:policy, :workers}, {:bad_return, [%{id: "idle"}]}}}
      assert [%{id: "idle", running: true}] = Octoroom.Room.state(ctx.room_id).workers
      assert Process.alive?(worker)

      # Fixed: the same worker runs on.
      :ok = Octoroom.Room.assign(ctx.room_id, :workers, nil)
      assert [%{id: "idle", running: true}] = Octoroom.Room.state(ctx.room_id).workers
      refute_receive {:idle_started, _}, 50
      assert Process.alive?(worker)
      refute_receive {:DOWN, ^ref, _, _, _}, 50
    end

    test "an update_meta/3 function that fails leaves the metadata alone", ctx do
      Octoroom.subscribe(ctx.room_id, scope: :room)
      alice = join(ctx, "alice", PolicyRoom)
      ref = Process.monitor(alice.server)
      update = &Octoroom.Room.update_meta(ctx.room_id, alice.id, &1)

      assert {:error, %RuntimeError{message: "oops"}} = update.(fn _ -> raise "oops" end)
      assert_receive {:octoroom, _, {:error, {:policy, :update_meta}, %RuntimeError{}}}
      assert {:error, {:throw, :x}} = update.(fn _ -> throw(:x) end)
      assert {:error, {:bad_return, :nope}} = update.(fn _ -> :nope end)
      assert [%{meta: %{name: "alice"} = meta}] = Octoroom.Room.state(ctx.room_id).participants
      refute Map.has_key?(meta, :x)

      assert :ok = update.(&Map.put(&1, :x, 1))
      assert [%{meta: %{x: 1}}] = Octoroom.Room.state(ctx.room_id).participants
      refute_receive {:DOWN, ^ref, _, _, _}, 50
    end

    test "a join with malformed metadata is refused, and an empty room stops again", ctx do
      for meta <- [nil, %{publish: :mic}, %{"publish" => "mic"}, %{publish: ["mic", :camera]}] do
        assert {:error, {:bad_meta, ^meta}} =
                 Octoroom.Room.join(GroupRoom, ctx.room_id, meta, ctx.opts)

        Process.sleep(20)
        assert Server.whereis(ctx.room_id) == nil
      end

      # A running room refuses the join and carries on.
      alice = join(ctx, "alice")
      ref = Process.monitor(alice.server)

      assert {:error, {:bad_meta, nil}} =
               Octoroom.Room.join(GroupRoom, ctx.room_id, nil, ctx.opts)

      publish(ctx, alice)
      refute_receive {:DOWN, ^ref, _, _, _}, 50
      assert [%{media: :live}] = Octoroom.Room.state(ctx.room_id).participants
    end

    test "update_meta/3 can't set a malformed publish list", ctx do
      alice = join(ctx, "alice")
      ref = Process.monitor(alice.server)

      assert {:error, {:bad_return, %{publish: "mic"}}} =
               Octoroom.Room.update_meta(ctx.room_id, alice.id, &Map.put(&1, :publish, "mic"))

      publish(ctx, alice)
      refute_receive {:DOWN, ^ref, _, _, _}, 50
    end

    test "metadata that slips past the join's check is refused publishing", ctx do
      # A resume carries metadata straight from its data, without a join.
      data = %{participant_id: "mallory", session_id: nil, meta: %{publish: :mic}}
      mallory = Client.resume("mallory", GroupRoom, ctx.room_id, data, ctx.opts)
      ref = Process.monitor(mallory.server)

      Server.publish(mallory.server, mallory.id, "offer", %{"mic" => "0"}, :pub)

      assert_receive {:client, "mallory",
                      {:octoroom_signal, :reply, :pub, {:error, :not_allowed}}}

      refute_receive {:DOWN, ^ref, _, _, _}, 50
    end

    test "a mount/1 that fails fails the join with a clear reason", ctx do
      assert {:error, {:mount_failed, %RuntimeError{message: "no assigns"}}} =
               Octoroom.Room.join(PolicyRoom, "raise-" <> ctx.room_id, %{}, ctx.opts)

      assert {:error, {:mount_failed, {:bad_return, :ok}}} =
               Octoroom.Room.join(PolicyRoom, "bad-" <> ctx.room_id, %{}, ctx.opts)
    end
  end

  # The metadata changes either way; the policy fails in the reconcile after.
  defp update_policy(ctx, client, policy),
    do: :ok = Octoroom.Room.update_meta(ctx.room_id, client.id, &Map.put(&1, :policy, policy))
end
