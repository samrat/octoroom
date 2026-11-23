defmodule Octoroom.WorkerVideoOutputTest do
  use ExUnit.Case, async: true

  alias Octoroom.{Outlet, Peer, Room, Track, Worker}
  alias Octoroom.Cloudflare.Local
  alias Octoroom.Test.{Client, FakeCloudflare, FakePeerMedia}

  defmodule AvatarWorker do
    use Octoroom.Worker, audio: [rate: 16_000, channels: 1]

    @impl true
    def init(test_pid, ctx) do
      send(test_pid, {:worker_init, ctx.outputs, ctx.output_kinds})
      {:ok, %{test: test_pid}}
    end

    @impl true
    def handle_info({:send_video, packet}, state) do
      {:ok, state, play_video: {:default_video, packet}}
    end

    def handle_info({:octoroom, :video_pli, output}, state) do
      send(state.test, {:video_pli, output})
      {:ok, state}
    end

    def handle_info(_msg, state), do: {:ok, state}
  end

  defmodule VideoAgentRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}

    @impl true
    def workers(%{participants: []}), do: []

    def workers(%{participants: [p | _]}) do
      [
        worker("avatar", AvatarWorker,
          outputs: ["avatar", Track.video("avatar/video")],
          args: p.meta.test
        )
      ]
    end
  end

  describe "Room.worker/3 video outputs" do
    test "records video output kinds from Track.video/1 and {:video, name}" do
      spec1 = Room.worker("bot", AvatarWorker, outputs: ["bot", Track.video("bot/video")])
      assert spec1.outputs == ["bot", "bot/video"]
      assert spec1.output_kinds == %{"bot/video" => :video}

      spec2 = Room.worker("bot", AvatarWorker, outputs: ["bot", {:video, "bot/video"}])
      assert spec2.outputs == ["bot", "bot/video"]
      assert spec2.output_kinds == %{"bot/video" => :video}

      spec3 = Room.worker("bot", AvatarWorker, outputs: ["bot"])
      assert spec3.outputs == ["bot"]
      refute Map.has_key?(spec3, :output_kinds)
      refute Map.has_key?(spec3, :video_inputs)

      spec4 =
        Room.worker("bot", AvatarWorker,
          inputs: ["alice/mic", "alice/camera"],
          video_inputs: :rtp,
          outputs: ["bot", Track.video("bot/video")]
        )

      assert spec4.video_inputs == :rtp

      ops =
        Octoroom.Reconciler.diff_workers([spec4], %{
          workers: %{},
          outlets: %{},
          inlets: [],
          tracks: %{"alice/mic" => :live, "alice/camera" => :live}
        })

      assert {:start_inlet, {"bot", "alice/mic"}} in ops
      assert {:start_inlet, {"bot", "alice/camera"}} in ops
    end
  end

  describe "video Inlet" do
    test "forwards raw video RTP packets and codec directly to the worker" do
      room_id = "video-inlet-#{System.unique_integer([:positive])}"
      {:ok, _} = Registry.register(Octoroom.Registry, {:worker, room_id, "avatar"}, :test)

      inlet =
        start_supervised!(
          {Octoroom.Inlet,
           %{room_id: room_id, worker_id: "avatar", input: "alice/camera", kind: :video}}
        )

      packet = ExRTP.Packet.new(<<0x87, 0x00>>, sequence_number: 1, timestamp: 90, marker: true)
      send(inlet, {:octoroom_video_rtp, packet, :vp9})

      assert_receive {:octoroom_video_rtp, "alice/camera", ^packet, :vp9}, 500
      assert Octoroom.Inlet.stats(inlet).forwarded == 1
    end
  end

  describe "video Outlet" do
    test "goes live on first video RTP packet and forwards packets" do
      room_id = "video-outlet-#{System.unique_integer([:positive])}"
      test_pid = self()

      outlet =
        start_supervised!(
          {Outlet, %{room_id: room_id, name: "avatar/video", kind: :video, server: test_pid}}
        )

      packet =
        ExRTP.Packet.new(<<0x10, 0x00, 0x9D, 0x01, 0x2A>>, sequence_number: 1, timestamp: 90)

      Outlet.play_video(room_id, "avatar/video", packet)
      assert Outlet.stats(room_id, "avatar/video").dropped == 1
      refute_receive {:outlet_live, _, _}, 50

      send(outlet, {:octoroom_sink, {:video_rtp, &send(test_pid, {:forwarded, &1})}})
      refute_receive {:outlet_live, _, _}, 50

      Outlet.play_video(room_id, "avatar/video", packet)
      assert_receive {:forwarded, ^packet}
      assert_receive {:outlet_live, "avatar/video", ^outlet}
      assert Outlet.stats(room_id, "avatar/video").live
      assert Outlet.stats(room_id, "avatar/video").sent == 1
    end
  end

  describe "room video output end-to-end (FakePeerMedia)" do
    test "publishes worker video track, delivers kind :video to client, and forwards video RTP" do
      {:ok, fake} = FakeCloudflare.start_link(self())
      room_id = "video-agent-room-#{System.unique_integer([:positive])}"
      opts = [cloudflare: FakeCloudflare.config(fake), peer_media: FakePeerMedia]

      client = Client.join("alice", VideoAgentRoom, room_id, %{test: self()}, opts)

      assert_receive {:worker_init, ["avatar", "avatar/video"], %{"avatar/video" => :video}},
                     1_000

      assert_receive {:video_pli, "avatar/video"}, 1_000

      Room.Server.publish(client.server, client.id, "offer:alice", %{"mic" => "0"}, :pub)

      assert_receive {:client, "alice",
                      {:octoroom_signal, :reply, :pub, {:ok, %{sdp: "answer:" <> session}}}}

      FakeCloudflare.mark_live(fake, session, "#{client.id}/mic")
      Room.Server.connected(client.server, client.id)

      # Audio outlet goes live right away; video outlet waits for first video RTP packet.
      assert_receive {:client, "alice", {:octoroom_signal, :renegotiate, %{op_id: op1}}}, 1_000
      Room.Server.answer(client.server, client.id, op1, "answer", :ans1)
      assert_receive {:client, "alice", {:octoroom_signal, :reply, :ans1, {:ok, _}}}

      assert_receive {:client, "alice", {:octoroom_signal, :tracks, %{added: audio_tracks}}},
                     1_000

      assert Enum.any?(audio_tracks, &(&1.track == "avatar" and &1.kind == :audio))

      packet =
        ExRTP.Packet.new(<<0x10, 0x00, 0x9D, 0x01, 0x2A>>,
          sequence_number: 42,
          timestamp: 3_000,
          marker: true
        )

      :ok = Worker.send(room_id, "avatar", {:send_video, packet})

      assert_receive {:client, "alice", {:octoroom_signal, :renegotiate, %{op_id: op2}}}, 1_000
      Room.Server.answer(client.server, client.id, op2, "answer", :ans2)
      assert_receive {:client, "alice", {:octoroom_signal, :reply, :ans2, {:ok, _}}}

      assert_receive {:client, "alice", {:octoroom_signal, :tracks, %{added: video_tracks}}},
                     1_000

      assert Enum.any?(
               video_tracks,
               &(&1.track == "avatar/video" and &1.kind == :video and &1.worker_id == "avatar")
             )

      Client.stop(client)
    end
  end

  describe "Peer.WebRTC video output over Cloudflare.Local" do
    test "pushes video track, forwards RTP packets, and routes RTCP PLI back" do
      sfu_name = :"local_video_sfu_#{System.unique_integer([:positive])}"
      start_supervised!({Local, name: sfu_name})
      cf = Local.config(sfu_name)
      test_pid = self()

      outlet =
        spawn_link(fn ->
          receive do
            {:octoroom_sink, sink} -> send(test_pid, {:video_sink, sink})
          end

          Process.sleep(:infinity)
        end)

      peer =
        start_supervised!(
          {Peer,
           %{
             room_id: "local-video-test",
             worker_id: "avatar",
             server: test_pid,
             cloudflare: cf,
             media: Octoroom.Peer.WebRTC
           }}
        )

      Peer.push(peer, "avatar/video", "out-video", outlet, :video)

      assert_receive {:peer_result, "avatar", ^peer, {:pushed, "avatar/video", pub_session}},
                     5_000

      assert_receive {:peer_result, "avatar", ^peer, :connected}, 5_000
      assert_receive {:video_sink, {:rtp, pub_pc, pub_track_id}}, 5_000

      # Connect a subscriber PeerConnection via Local SFU and pull the worker's video track.
      {:ok, sub_session} = Octoroom.Cloudflare.new_session(cf)

      {:ok, %{sdp: offer, tracks: [%{mid: _mid}]}} =
        Octoroom.Cloudflare.pull_tracks(cf, sub_session, [
          %{session_id: pub_session, track_name: "out-video"}
        ])

      {:ok, sub_pc} =
        ExWebRTC.PeerConnection.start_link(
          ice_servers: [],
          ice_aggressive_nomination: true,
          audio_codecs: [:opus],
          video_codecs: Octoroom.Peer.WebRTC.default_video_codecs()
        )

      on_exit(fn ->
        if Process.alive?(sub_pc), do: ExWebRTC.PeerConnection.close(sub_pc)
      end)

      :ok =
        ExWebRTC.PeerConnection.set_remote_description(sub_pc, %ExWebRTC.SessionDescription{
          type: :offer,
          sdp: offer
        })

      {:ok, answer} = ExWebRTC.PeerConnection.create_answer(sub_pc)
      :ok = ExWebRTC.PeerConnection.set_local_description(sub_pc, answer)

      if ExWebRTC.PeerConnection.get_ice_gathering_state(sub_pc) != :complete do
        receive do
          {:ex_webrtc, ^sub_pc, {:ice_gathering_state_change, :complete}} -> :ok
        after
          5_000 -> :ok
        end
      end

      :ok =
        Octoroom.Cloudflare.renegotiate(
          cf,
          sub_session,
          ExWebRTC.PeerConnection.get_local_description(sub_pc).sdp
        )

      receive do
        {:ex_webrtc, ^sub_pc, {:connection_state_change, :connected}} -> :ok
      after
        5_000 -> flunk("subscriber peer connection did not connect")
      end

      # Select VP9 on the worker's sender and verify Local SFU preserves VP9 to the subscriber.
      assert :ok = Octoroom.Peer.WebRTC.select_sender_codec(pub_pc, pub_track_id, :vp9)

      sub_vp9_pt =
        sub_pc
        |> ExWebRTC.PeerConnection.get_transceivers()
        |> Enum.find(&(&1.kind == :video))
        |> Map.fetch!(:codecs)
        |> Enum.find(&(String.downcase(&1.mime_type) == "video/vp9"))
        |> Map.fetch!(:payload_type)

      vp9_payload = <<0x87, 0x00, 0x9D, 0x01, 0x2A, 0x80, 0x00, 0x60, 0x00>>

      for seq <- 1..3 do
        packet =
          ExRTP.Packet.new(vp9_payload,
            sequence_number: seq,
            timestamp: seq * 3_000,
            marker: true
          )

        ExWebRTC.PeerConnection.send_rtp(pub_pc, pub_track_id, packet)
      end

      assert_receive {:ex_webrtc, ^sub_pc,
                      {:rtp, _sub_track_id, _rid,
                       %ExRTP.Packet{payload: ^vp9_payload, payload_type: ^sub_vp9_pt}}},
                     5_000
    end
  end
end
