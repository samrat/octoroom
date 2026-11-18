defmodule Octoroom.VideoTest do
  use ExUnit.Case, async: true

  alias Octoroom.Room.Server
  alias Octoroom.Test.{Client, FakeCloudflare}

  defmodule VideoRoom do
    use Octoroom.Room

    @impl true
    def join(%{"name" => name}, _socket), do: {:ok, %{name: name}}
  end

  # Listeners with `video: false` get audio only.
  defmodule AudioOnlyRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{video: true}}

    @impl true
    def subscriptions(listener, room) do
      for track <- default_subscriptions(listener, room),
          listener.meta.video or track.kind == :audio,
          do: track
    end
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

  defp join(ctx, name, meta \\ %{}, module \\ VideoRoom) do
    Client.join(name, module, ctx.room_id, Map.merge(%{name: name}, meta), ctx.opts)
  end

  # Publishes `mids` (source => mid) as the client's first publish, then
  # reports it connected once Cloudflare has its first packets.
  defp publish(ctx, client, mids \\ %{"mic" => "0", "camera" => "1"}) do
    Server.publish(client.server, client.id, "offer:#{client.name}", mids, :pub)

    assert_receive {:client, name,
                    {:octoroom_signal, :reply, :pub, {:ok, %{sdp: "answer:" <> session}}}}

    assert name == client.name

    for {source, _} <- mids,
        do: FakeCloudflare.mark_live(ctx.fake, session, "#{client.id}/#{source}")

    Server.connected(client.server, client.id)
    Map.put(client, :session, session)
  end

  defp accept_pull(client, timeout \\ 200) do
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
    mids
  end

  defp hears(ctx) do
    for p <- Octoroom.Room.state(ctx.room_id).participants, into: %{}, do: {p.meta.name, p.hears}
  end

  test "participants see each other's cameras, labelled by kind and source", ctx do
    Octoroom.subscribe(ctx.room_id, scope: :room)
    alice = join(ctx, "alice") |> then(&publish(ctx, &1))
    alice_id = alice.id

    assert_receive {:octoroom, _,
                    {:published, %{id: ^alice_id, tracks: %{"mic" => mic, "camera" => camera}}}}

    assert mic == %{kind: :audio, muted: false}
    assert camera == %{kind: :video, muted: false}

    bob = join(ctx, "bob") |> then(&publish(ctx, &1))

    assert [
             %{track: cam, kind: :video, source: "camera", participant_id: ^alice_id, mid: _},
             %{track: mic_name, kind: :audio, source: "mic", gain: 1.0}
           ] = accept_pull(bob)

    assert cam == "#{alice_id}/camera"
    assert mic_name == "#{alice_id}/mic"
    assert [_, _] = accept_pull(alice)

    assert hears(ctx)["alice"] == ["#{bob.id}/camera", "#{bob.id}/mic"]

    [a, _] = Octoroom.Room.state(ctx.room_id).participants
    assert a.media == :live
    assert a.mic == :live

    assert a.tracks == %{
             "mic" => %{status: :live, muted: false},
             "camera" => %{status: :live, muted: false}
           }
  end

  test "a camera turned on later is pushed through the queue, then pulled", ctx do
    alice = join(ctx, "alice") |> then(&publish(ctx, &1, %{"mic" => "0"}))
    bob = join(ctx, "bob") |> then(&publish(ctx, &1, %{"mic" => "0"}))
    accept_pull(alice)
    accept_pull(bob)

    Server.publish_tracks(alice.server, alice.id, ["camera"], :cam)

    assert_receive {:client, "alice",
                    {:octoroom_signal, :push, %{op_id: op, sources: ["camera"]}}}

    Server.push_offer(alice.server, alice.id, op, "camera offer", %{"camera" => "2"}, :offer)

    assert_receive {:client, "alice",
                    {:octoroom_signal, :reply, :offer, {:ok, %{sdp: "answer:" <> _}}}}

    assert_receive {:client, "alice", {:octoroom_signal, :reply, :cam, {:ok, %{}}}}

    assert_receive {:cloudflare, :push_tracks,
                    [session, "camera offer", [%{mid: "2", track_name: name}]]}

    assert session == alice.session
    assert name == "#{alice.id}/camera"

    # Pending until alice says it's flowing.
    refute_receive {:client, "bob", {:octoroom_signal, :renegotiate, _}}, 50
    FakeCloudflare.mark_live(ctx.fake, alice.session, name)
    Server.connected(alice.server, alice.id)
    assert [%{track: ^name, kind: :video}] = accept_pull(bob)

    # Publishing it twice is refused.
    Server.publish_tracks(alice.server, alice.id, ["camera"], :again)

    assert_receive {:client, "alice",
                    {:octoroom_signal, :reply, :again, {:error, :already_published}}}
  end

  test "unpublishing closes everyone's pulls first, then the publisher's track", ctx do
    Octoroom.subscribe(ctx.room_id, scope: :room)
    alice = join(ctx, "alice") |> then(&publish(ctx, &1))
    bob = join(ctx, "bob") |> then(&publish(ctx, &1, %{"mic" => "0"}))
    accept_pull(alice)
    accept_pull(bob)
    alice_id = alice.id

    Server.unpublish(alice.server, alice.id, "camera", :off)
    assert_receive {:octoroom, _, {:updated, %{id: ^alice_id, tracks: tracks}}}
    assert Map.keys(tracks) == ["mic"]

    # Alice's own close waits for bob's.
    refute_receive {:client, "alice", {:octoroom_signal, :close, _}}, 50
    [bob_mid] = accept_close(bob)
    assert_receive {:client, "bob", {:octoroom_signal, :tracks, %{removed: [^bob_mid]}}}

    assert ["1"] = accept_close(alice)
    assert_receive {:client, "alice", {:octoroom_signal, :reply, :off, {:ok, %{}}}}
    refute_receive {:client, "alice", {:octoroom_signal, :tracks, _}}, 50

    assert FakeCloudflare.tracks(ctx.fake, alice.session) |> Map.keys() |> Enum.sort() == [
             "0",
             "2"
           ]

    assert hears(ctx)["bob"] == ["#{alice_id}/mic"]

    [a, _] = Octoroom.Room.state(ctx.room_id).participants
    assert Map.keys(a.tracks) == ["mic"]

    # It can be published again.
    Server.publish_tracks(alice.server, alice.id, ["camera"], :on)
    assert_receive {:client, "alice", {:octoroom_signal, :push, %{sources: ["camera"]}}}
  end

  test "mute is a flag on the publication, with no renegotiation", ctx do
    Octoroom.subscribe(ctx.room_id, scope: :room)
    alice = join(ctx, "alice") |> then(&publish(ctx, &1))
    alice_id = alice.id
    Server.mute(alice.server, alice.id, "camera", true)

    assert_receive {:octoroom, _,
                    {:updated, %{id: ^alice_id, tracks: %{"camera" => %{muted: true}}}}}

    refute_receive {:client, "alice", {:octoroom_signal, :renegotiate, _}}, 50
    refute_receive {:client, "alice", {:octoroom_signal, :push, _}}, 10
  end

  test "metadata limits what a participant may publish", ctx do
    alice = join(ctx, "alice", %{publish: ["mic"]})
    Server.publish(alice.server, alice.id, "offer", %{"mic" => "0", "camera" => "1"}, :pub)
    assert_receive {:client, "alice", {:octoroom_signal, :reply, :pub, {:error, :not_allowed}}}

    alice = publish(ctx, alice, %{"mic" => "0"})
    Server.publish_tracks(alice.server, alice.id, ["screen"], :screen)
    assert_receive {:client, "alice", {:octoroom_signal, :reply, :screen, {:error, :not_allowed}}}
    Server.publish_tracks(alice.server, alice.id, ["hologram"], :what)

    assert_receive {:client, "alice",
                    {:octoroom_signal, :reply, :what, {:error, :unknown_source}}}
  end

  test "a policy can leave video out for one listener", ctx do
    a = join(ctx, "a", %{video: true}, AudioOnlyRoom) |> then(&publish(ctx, &1))
    b = join(ctx, "b", %{video: false}, AudioOnlyRoom) |> then(&publish(ctx, &1))

    assert [%{kind: :audio}] = accept_pull(b)
    assert [_, _] = accept_pull(a)

    :ok = Octoroom.Room.update_meta(ctx.room_id, b.id, &%{&1 | video: true})
    assert [%{kind: :video}] = accept_pull(b)
  end

  test "workers take audio inputs only" do
    p = %Octoroom.Participant{id: "a"}

    assert_raise ArgumentError, ~r/video/, fn ->
      Octoroom.Room.worker("w", Octoroom.Worker, inputs: [Octoroom.Room.camera(p)])
    end

    assert %{inputs: ["a/screen_audio"]} =
             Octoroom.Room.worker("w", Octoroom.Worker, inputs: ["a/screen_audio"])
  end

  test "gain is for audio only" do
    p = %Octoroom.Participant{id: "a"}
    assert %{gain: 0.5} = Octoroom.Room.gain(Octoroom.Room.screen_audio(p), 0.5)
    assert_raise ArgumentError, fn -> Octoroom.Room.gain(Octoroom.Room.camera(p), 0.5) end
  end

  describe "after a restart" do
    test "every published source is adopted", ctx do
      opts = Keyword.put(ctx.opts, :grace_ms, 200)
      ctx = %{ctx | opts: opts}
      alice = join(ctx, "alice") |> then(&publish(ctx, &1))
      bob = join(ctx, "bob") |> then(&publish(ctx, &1, %{"mic" => "0"}))
      accept_pull(alice)
      accept_pull(bob)

      resume = fn c -> Map.merge(c.reply.resume, %{session_id: c.session}) end
      {a_data, b_data} = {resume.(alice), resume.(bob)}
      Process.exit(alice.server, :kill)
      Process.sleep(20)

      alice2 = Client.resume("alice", VideoRoom, ctx.room_id, a_data, opts)
      _bob2 = Client.resume("bob", VideoRoom, ctx.room_id, b_data, opts)
      assert alice2.reply.resumed

      assert_receive {:client, "bob", {:octoroom_signal, :tracks, %{reset: true, added: added}}},
                     500

      assert Enum.map(added, & &1.source) |> Enum.sort() == ["camera", "mic"]
      refute_receive {:client, _, {:octoroom_signal, :renegotiate, _}}, 100

      [a, _] = Octoroom.Room.state(ctx.room_id).participants
      assert Map.keys(a.tracks) |> Enum.sort() == ["camera", "mic"]
    end
  end
end
