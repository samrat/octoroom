defmodule Octoroom.Cloudflare.LocalTest do
  use ExUnit.Case, async: true

  alias ExRTCP.Packet.PayloadFeedback.PLI
  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}
  alias Octoroom.Cloudflare
  alias Octoroom.Cloudflare.Local
  alias Octoroom.Peer

  setup do
    name = :"local_sfu_#{System.unique_integer([:positive])}"
    start_supervised!({Local, name: name})
    {:ok, cf: Local.config(name)}
  end

  test "returns empty_track_error when pulling an unpublished track", %{cf: cf} do
    assert {:ok, session} = Cloudflare.new_session(cf)

    assert {:ok,
            %{
              sdp: nil,
              renegotiate: false,
              tracks: [
                %{session_id: "missing", track_name: "p1/mic", error: "empty_track_error"}
              ]
            }} =
             Cloudflare.pull_tracks(cf, session, [
               %{session_id: "missing", track_name: "p1/mic"}
             ])
  end

  test "forwards real Opus RTP packets end-to-end between two Octoroom.Peer workers", %{cf: cf} do
    test_pid = self()

    inlet =
      spawn_link(fn ->
        loop = fn loop ->
          receive do
            {:octoroom_rtp, packet} ->
              send(test_pid, {:received_rtp, packet})
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    outlet =
      spawn_link(fn ->
        receive do
          {:octoroom_sink, sink} -> send(test_pid, {:outlet_sink, sink})
        end
      end)

    pub_peer =
      start_supervised!(
        {Peer, %{worker_id: "pub", server: test_pid, cloudflare: cf, room_id: "local-test"}},
        id: :pub_peer
      )

    sub_peer =
      start_supervised!(
        {Peer, %{worker_id: "sub", server: test_pid, cloudflare: cf, room_id: "local-test"}},
        id: :sub_peer
      )

    Peer.push(pub_peer, "voice", "room/voice", outlet)

    assert_receive {:peer_result, "pub", ^pub_peer, {:pushed, "voice", pub_session}}, 5_000
    assert_receive {:peer_result, "pub", ^pub_peer, :connected}, 5_000
    assert_receive {:outlet_sink, {:rtp, pub_pc, pub_track_id}}, 5_000

    Peer.pull(sub_peer, "room/voice", %{session_id: pub_session, track_name: "room/voice"}, inlet)

    assert_receive {:peer_result, "sub", ^sub_peer, {:pulled, "room/voice"}}, 5_000
    assert_receive {:peer_result, "sub", ^sub_peer, :connected}, 5_000

    assert {:ok, %{tracks: [%{location: :local, track_name: "room/voice", status: :active}]}} =
             Cloudflare.session_state(cf, pub_session)

    sub_session = Peer.session(sub_peer)

    assert {:ok,
            %{
              tracks: [
                %{
                  location: :remote,
                  track_name: "room/voice",
                  session_id: ^pub_session,
                  status: :active
                }
              ]
            }} = Cloudflare.session_state(cf, sub_session)

    # Send real RTP packets through pub_peer -> Local SFU -> sub_peer -> inlet
    payload = <<0xF8, 0xFF, 0xFE>>

    for seq <- 1..5 do
      packet = ExRTP.Packet.new(payload, sequence_number: seq, timestamp: seq * 960)
      PeerConnection.send_rtp(pub_pc, pub_track_id, packet)
    end

    assert_receive {:received_rtp, %ExRTP.Packet{payload: ^payload}}, 5_000

    # Closing the input removes the remote track and returns an answer SDP
    Peer.close(sub_peer, {:input, "room/voice"})

    assert_eventually(fn ->
      {:ok, %{tracks: []}} == Cloudflare.session_state(cf, sub_session)
    end)

    # Closing the publisher session marks it disconnected
    :ok = Local.close_session(cf, pub_session)
    assert {:error, :disconnected} = Cloudflare.session_state(cf, pub_session)
  end

  test "forwards video RTP and PLI feedback between two WebRTC peers", %{cf: cf} do
    {:ok, pub_session} = Cloudflare.new_session(cf)
    {:ok, sub_session} = Cloudflare.new_session(cf)

    {:ok, pub_pc} =
      PeerConnection.start_link(
        ice_servers: [],
        ice_aggressive_nomination: true,
        video_codecs: [:vp8]
      )

    {:ok, sub_pc} =
      PeerConnection.start_link(
        ice_servers: [],
        ice_aggressive_nomination: true,
        video_codecs: [:vp8]
      )

    on_exit(fn ->
      for pc <- [pub_pc, sub_pc] do
        try do
          PeerConnection.close(pc)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    video_track = MediaStreamTrack.new(:video)
    {:ok, _} = PeerConnection.add_transceiver(pub_pc, video_track, direction: :sendonly)
    {:ok, pub_offer} = PeerConnection.create_offer(pub_pc)
    :ok = PeerConnection.set_local_description(pub_pc, pub_offer)
    pub_sdp = wait_gathered_sdp(pub_pc)

    [pub_tr] = PeerConnection.get_transceivers(pub_pc)

    assert {:ok, %{sdp: pub_answer}} =
             Cloudflare.push_tracks(cf, pub_session, pub_sdp, [
               %{mid: pub_tr.mid, track_name: "p1/camera"}
             ])

    :ok =
      PeerConnection.set_remote_description(pub_pc, %SessionDescription{
        type: :answer,
        sdp: pub_answer
      })

    wait_connected(pub_pc)

    assert {:ok,
            %{
              sdp: sub_offer,
              renegotiate: true,
              tracks: [%{session_id: ^pub_session, track_name: "p1/camera", mid: sub_mid}]
            }} =
             Cloudflare.pull_tracks(cf, sub_session, [
               %{session_id: pub_session, track_name: "p1/camera"}
             ])

    :ok =
      PeerConnection.set_remote_description(sub_pc, %SessionDescription{
        type: :offer,
        sdp: sub_offer
      })

    {:ok, sub_answer} = PeerConnection.create_answer(sub_pc)
    :ok = PeerConnection.set_local_description(sub_pc, sub_answer)
    sub_answer_sdp = wait_gathered_sdp(sub_pc)

    assert :ok = Cloudflare.renegotiate(cf, sub_session, sub_answer_sdp)
    wait_connected(sub_pc)

    sub_tr = Enum.find(PeerConnection.get_transceivers(sub_pc), &(&1.mid == sub_mid))
    sub_rx_track_id = sub_tr.receiver.track.id

    # Minimal VP8 payload (1-byte descriptor 0x10 + keyframe header)
    vp8_payload = <<0x10, 0x00, 0x00, 0x9D, 0x01, 0x2A, 0x10, 0x00, 0x10, 0x00>>

    for seq <- 1..5 do
      packet = ExRTP.Packet.new(vp8_payload, sequence_number: seq, timestamp: seq * 3000)
      PeerConnection.send_rtp(pub_pc, video_track.id, packet)
    end

    assert_receive {:ex_webrtc, ^sub_pc,
                    {:rtp, ^sub_rx_track_id, _, %ExRTP.Packet{payload: ^vp8_payload}}},
                   5_000

    # Subscriber sends a PLI -> Local SFU forwards PLI to publisher
    :ok = PeerConnection.send_pli(sub_pc, sub_rx_track_id)

    assert_receive {:ex_webrtc, ^pub_pc, {:rtcp, rtcp_packets}}, 5_000
    assert Enum.any?(rtcp_packets, fn {_id, pkt} -> match?(%PLI{}, pkt) end)

    # Force-closing the track removes it from session state
    assert {:ok, %{sdp: nil}} = Cloudflare.close_tracks(cf, sub_session, [sub_mid], nil)
    assert {:ok, %{tracks: []}} = Cloudflare.session_state(cf, sub_session)
  end

  defp wait_gathered_sdp(pc) do
    if PeerConnection.get_ice_gathering_state(pc) != :complete do
      receive do
        {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}} -> :ok
      after
        5_000 -> flunk("ICE gathering timed out")
      end
    end

    PeerConnection.get_local_description(pc).sdp
  end

  defp wait_connected(pc) do
    if PeerConnection.get_connection_state(pc) != :connected do
      receive do
        {:ex_webrtc, ^pc, {:connection_state_change, :connected}} -> :ok
      after
        5_000 -> flunk("PeerConnection did not connect")
      end
    end
  end

  defp assert_eventually(fun, attempts \\ 30) do
    if fun.() do
      :ok
    else
      if attempts <= 1, do: flunk("condition did not become true")
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end
end
