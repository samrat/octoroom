defmodule Octoroom.Agent.OpenAILive.WebRTCTest do
  use ExUnit.Case, async: true

  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}
  alias Octoroom.Agent.OpenAILive.WebRTC

  defmodule FakeSideband do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def send_json(pid, frame), do: GenServer.cast(pid, {:send_json, frame})
    def close(pid), do: GenServer.cast(pid, :close)

    @impl true
    def init(opts) do
      parent = Keyword.fetch!(opts, :parent)
      test = Application.get_env(:octoroom_agents, :fake_sideband_test)
      send(test, {:sideband_started, self(), opts[:url], opts[:api_key]})
      send(parent, {:openai_live_sideband, :connected})
      {:ok, %{parent: parent, test: test}}
    end

    @impl true
    def handle_cast({:send_json, frame}, state) do
      send(state.test, {:sideband_sent, frame})
      {:noreply, state}
    end

    def handle_cast(:close, state) do
      send(state.test, :sideband_closed)
      {:stop, :normal, state}
    end

    @impl true
    def handle_info({:deliver, event}, state) do
      send(state.parent, {:openai_live_sideband, event})
      {:noreply, state}
    end
  end

  test "negotiates audio-only SDP over loopback, attaches sideband, and gates silent vs active audio" do
    test = self()
    Application.put_env(:octoroom_agents, :fake_sideband_test, test)
    on_exit(fn -> Application.delete_env(:octoroom_agents, :fake_sideband_test) end)

    # Fake OpenAI remote WebRTC audio peer running in a helper process.
    remote =
      spawn_link(fn ->
        {:ok, pc} =
          PeerConnection.start_link(
            ice_servers: [],
            ice_aggressive_nomination: true,
            video_codecs: []
          )

        remote_loop(pc, test, nil)
      end)

    exchange = fn body, api_key, endpoint ->
      send(test, {:exchange, body, api_key, endpoint})
      send(remote, {:offer, body.transport.sdp, self()})

      receive do
        {:answer, answer_sdp} -> {:ok, %{session_id: "live_webrtc_1", sdp: answer_sdp}}
      after
        5_000 -> {:error, :timeout}
      end
    end

    {:ok, client} =
      WebRTC.start_link(
        api_key: "sk-test",
        parent: test,
        setup: [
          model: "gpt-live-1.1",
          voice: "marin",
          instructions: "Be brief.",
          idle_timeout_s: 15,
          wake_policy: :speech
        ],
        exchange: exchange,
        sideband_mod: FakeSideband
      )

    # Verify POST body omits audio.format and carries idle_timeout_s + wake_policy.
    assert_receive {:exchange, body, "sk-test", "https://api.openai.com/v1/live/sessions"}, 5_000
    assert body.session.model == "gpt-live-1.1"
    assert body.session.audio == %{output: %{voice: "marin"}}
    assert body.session.idle_timeout_s == 15
    assert body.session.wake_policy == %{type: "speech"}
    assert body.transport.type == "webrtc"
    assert is_binary(body.transport.sdp)

    assert_receive {:sideband_started, sb,
                    "wss://api.openai.com/v1/live/sessions/live_webrtc_1/attach", "sk-test"},
                   5_000

    assert_receive {:openai_live_socket, :connected}, 5_000

    # Sideband delivers session.started and transcript deltas.
    send(sb, {:deliver, {:session_started, %{"id" => "live_webrtc_1"}}})
    assert_receive {:openai_live_socket, {:session_started, %{"id" => "live_webrtc_1"}}}, 2_000

    send(sb, {:deliver, {:transcription, :assistant, "Hello!"}})
    assert_receive {:openai_live_socket, {:transcription, :assistant, "Hello!"}}, 2_000

    # Client sends commentary over sideband.
    WebRTC.send_commentary(client, "Hi there")

    assert_receive {:sideband_sent,
                    %{type: "session.commentary.append", content: "Hi there", delegation_id: nil}},
                   2_000

    # Client sends 16 kHz PCM audio and remote receives Opus RTP packets.
    pcm_16k = for _ <- 1..320, into: <<>>, do: <<2_000::little-signed-16>>
    WebRTC.send_audio(client, pcm_16k, sample_rate: 16_000)
    assert_receive {:remote_rtp, _packet}, 2_000

    # Remote sends silent Opus frames: gated out, no {:audio, ...} delivered.
    send(remote, {:send_audio, :silence, 3})
    refute_receive {:openai_live_socket, {:audio, _, _}}, 200

    # Remote sends non-silent Opus frames: decoded to 24 kHz mono PCM and delivered.
    send(remote, {:send_audio, :tone, 3})
    assert_receive {:openai_live_socket, {:audio, pcm_24k, sample_rate: 24_000}}, 2_000
    assert byte_size(pcm_24k) > 0

    # Graceful close closes the sideband and stops cleanly.
    ref = Process.monitor(client)
    WebRTC.close(client)
    assert_receive :sideband_closed, 2_000
    assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 2_000

    send(remote, :stop)
  end

  test "surfaces non-retryable 4xx HTTP errors without crashing" do
    test = self()

    exchange = fn _body, _api_key, _endpoint ->
      {:error, :non_retryable, %{"code" => "invalid_value", "message" => "bad request"}}
    end

    {:ok, client} =
      WebRTC.start_link(
        api_key: "sk-test",
        parent: test,
        setup: [model: "gpt-live-1.1"],
        exchange: exchange,
        sideband_mod: FakeSideband
      )

    assert_receive {:openai_live_socket,
                    {:error, %{"code" => "invalid_value", "message" => "bad request"}}},
                   5_000

    WebRTC.close(client)
  end

  test "sideband_url converts HTTP endpoint to wss /attach URL" do
    assert WebRTC.sideband_url("https://api.openai.com/v1/live/sessions", "live_123") ==
             "wss://api.openai.com/v1/live/sessions/live_123/attach"

    assert WebRTC.sideband_url("http://localhost:4000/v1/live/sessions/", "live_123") ==
             "ws://localhost:4000/v1/live/sessions/live_123/attach"
  end

  defp remote_loop(pc, test, track_id, seq \\ 1, ts \\ 960, encoder \\ nil) do
    receive do
      {:offer, offer_sdp, reply_to} ->
        :ok =
          PeerConnection.set_remote_description(pc, %SessionDescription{
            type: :offer,
            sdp: offer_sdp
          })

        track = MediaStreamTrack.new(:audio)

        case PeerConnection.get_transceivers(pc) do
          [tr | _] ->
            :ok = PeerConnection.set_transceiver_direction(pc, tr.id, :sendrecv)
            :ok = PeerConnection.replace_track(pc, tr.sender.id, track)

          [] ->
            {:ok, _} = PeerConnection.add_transceiver(pc, track, direction: :sendrecv)
        end

        {:ok, answer} = PeerConnection.create_answer(pc)
        :ok = PeerConnection.set_local_description(pc, answer)

        if PeerConnection.get_ice_gathering_state(pc) != :complete do
          receive do
            {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}} -> :ok
          after
            5_000 -> :ok
          end
        end

        send(reply_to, {:answer, PeerConnection.get_local_description(pc).sdp})
        remote_loop(pc, test, track.id, seq, ts, encoder)

      {:ex_webrtc, ^pc, {:rtp, _tid, _rid, packet}} ->
        send(test, {:remote_rtp, packet})
        remote_loop(pc, test, track_id, seq, ts, encoder)

      {:send_audio, kind, count} ->
        encoder = encoder || Membrane.Opus.Encoder.Native.create(48_000, 2, 2048, -1000, 3001)

        pcm =
          case kind do
            :silence ->
              :binary.copy(<<0>>, 3_840)

            :tone ->
              for i <- 0..959, into: <<>> do
                sample = round(:math.sin(2 * :math.pi() * 440 * i / 48_000) * 10_000)
                <<sample::little-signed-16, sample::little-signed-16>>
              end
          end

        {seq, ts} =
          Enum.reduce(1..count, {seq, ts}, fn _, {s, t} ->
            {:ok, payload} = Membrane.Opus.Encoder.Native.encode_packet(encoder, pcm, 960)
            pkt = ExRTP.Packet.new(payload, sequence_number: s, timestamp: t, marker: s == 1)
            PeerConnection.send_rtp(pc, track_id, pkt)
            Process.sleep(20)
            {rem(s + 1, 65_536), rem(t + 960, 4_294_967_296)}
          end)

        remote_loop(pc, test, track_id, seq, ts, encoder)

      :stop ->
        PeerConnection.close(pc)

      _other ->
        remote_loop(pc, test, track_id, seq, ts, encoder)
    end
  end
end
