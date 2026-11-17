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
    Octoroom.subscribe(ctx.room_id)
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
    Octoroom.subscribe(ctx.room_id)
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
end
