defmodule Octoroom.Agent.NuanceLive.Session do
  @moduledoc false

  # One Nuance Live session:
  #
  #   1. Mints a single-use session token (`POST /session-tokens`) with the API key.
  #   2. Creates the conversation (`POST /conversation`) with the session token.
  #   3. Long-polls `GET /conversation/{id}/events?after=N` continuously to keep
  #      the conversation alive and follow `preparing` -> `admitted` -> `started` -> `ended`.
  #   4. Connects to Nuance's LiveKit room (`Signal` WebSocket + dual `ExWebRTC.PeerConnection`s:
  #      publisher for mic Opus RTP + `_reliable` DataChannel, subscriber for avatar audio/video
  #      RTP + incoming DataChannel events).
  #   5. Answers `clock-sync` pings immediately and relays `nuance_live` JSON events,
  #      decoded 24 kHz mono audio PCM, and encoded video RTP packets to `parent` as
  #      `{:nuance_live_socket, event}`.

  use GenServer

  require Logger

  alias ExWebRTC.{ICECandidate, MediaStreamTrack, PeerConnection, SessionDescription}
  alias ExWebRTC.RTP.JitterBuffer
  alias Octoroom.Agent.Audio.PCM16
  alias Octoroom.Agent.NuanceLive.{Protobuf, Protocol, Signal}
  alias Octoroom.Audio

  @http_timeout_ms 20_000
  @poll_timeout_ms 30_000
  @max_poll_errors 6

  @frame_ms 20
  @frame_samples 960
  @frame_bytes 3_840
  @max_lag_ms 100
  @max_queued_frames 10
  @silence :binary.copy(<<0>>, @frame_bytes)

  @out_rate 24_000
  @jitter_ms 40
  @silence_threshold 16
  @hangover_frames 15

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def send_audio(pid, audio, opts \\ []) when is_binary(audio) do
    rate = Keyword.get(opts, :sample_rate, 16_000)
    GenServer.cast(pid, {:send_audio, audio, rate})
  end

  def send_video(pid, %ExRTP.Packet{} = packet, codec \\ nil) do
    GenServer.cast(pid, {:send_video, packet, codec})
  end

  def send_json(pid, frame) when is_map(frame), do: GenServer.cast(pid, {:send_json, frame})
  def request_keyframe(pid), do: GenServer.cast(pid, :request_keyframe)
  def close(pid), do: GenServer.cast(pid, :close)

  @impl true
  def init(opts) do
    if Code.ensure_loaded?(ExSCTP) do
      Process.flag(:trap_exit, true)

      state = %{
        api_key: Keyword.fetch!(opts, :api_key),
        parent: Keyword.fetch!(opts, :parent),
        setup: Keyword.fetch!(opts, :setup),
        base_url:
          Keyword.get(opts, :base_url, Protocol.default_base_url()) |> String.trim_trailing("/"),
        webrtc_opts: Keyword.get(opts, :webrtc_opts, []),
        # HTTP lifecycle
        session_token: nil,
        conversation_id: nil,
        events_task: nil,
        admitted?: false,
        ended?: false,
        closing?: false,
        # LiveKit signaling & peer connections
        signal: nil,
        ping_timer: nil,
        ping_interval_ms: 15_000,
        pub_pc: nil,
        pub_track_id: nil,
        pub_video_track_id: nil,
        pub_video_codec: nil,
        pub_tracks_expected: 1,
        pub_tracks_published: 0,
        pub_remote_set?: false,
        pub_pending_ice: [],
        pub_offer_sent?: false,
        pub_connected?: false,
        reliable_ref: nil,
        reliable_open?: false,
        data_seq: 0,
        sub_pc: nil,
        sub_remote_set?: false,
        sub_pending_ice: [],
        sub_tracks: %{},
        video_track_id: nil,
        video_rid: nil,
        video_rtp_seen?: false,
        video_pli_pending?: false,
        video_pt: nil,
        video_codec: nil,
        pending_control: [],
        parts: [],
        streams: %{},
        # Outbound Opus RTP state
        encoder: nil,
        seq: :rand.uniform(65_536) - 1,
        timestamp: :rand.uniform(4_294_967_296) - 1,
        spurt: true,
        prev_frame: {0, 0},
        in_buffer: <<>>,
        in_queue: :queue.new(),
        in_queued: 0,
        rtp_next: nil,
        rtp_timer: nil,
        # Inbound Opus RTP state
        jitter: JitterBuffer.new(latency: @jitter_ms),
        jitter_timer: nil,
        decoders: %{},
        hangover: 0
      }

      send(self(), :start_session)
      {:ok, state}
    else
      Logger.error(
        "Nuance Live requires {:ex_sctp, \"~> 0.1.3\"} (and Rust) for WebRTC DataChannels. " <>
          "Add {:ex_sctp, \"~> 0.1.3\"} to your mix.exs and run `mix deps.get && mix deps.compile ex_webrtc --force`."
      )

      {:stop, :missing_ex_sctp}
    end
  end

  @impl true
  def handle_cast({:send_audio, pcm, rate}, %{pub_connected?: true} = state) do
    {room_pcm, prev} = Audio.to_room(pcm, rate, 1, state.prev_frame)
    {frames, rest} = split_frames(state.in_buffer <> room_pcm, [])
    {queue, queued} = enqueue_frames(state.in_queue, state.in_queued, frames)
    {:noreply, %{state | prev_frame: prev, in_buffer: rest, in_queue: queue, in_queued: queued}}
  end

  def handle_cast({:send_audio, _pcm, _rate}, state), do: {:noreply, state}

  def handle_cast(
        {:send_video, %ExRTP.Packet{} = packet, codec},
        %{pub_connected?: true, pub_pc: pc, pub_video_track_id: tid} = state
      )
      when is_pid(pc) and not is_nil(tid) do
    pub_video_codec =
      if codec != nil and codec != state.pub_video_codec do
        Octoroom.Peer.WebRTC.select_sender_codec(pc, tid, codec)
        codec
      else
        state.pub_video_codec
      end

    PeerConnection.send_rtp(pc, tid, packet)
    {:noreply, %{state | pub_video_codec: pub_video_codec}}
  end

  def handle_cast({:send_video, _packet, _codec}, state), do: {:noreply, state}

  def handle_cast({:send_json, frame}, state) do
    {:noreply, send_or_queue_nuance(state, frame)}
  end

  def handle_cast(
        :request_keyframe,
        %{sub_pc: pc, video_track_id: tid, video_rtp_seen?: true} = state
      )
      when is_pid(pc) and not is_nil(tid) do
    PeerConnection.send_pli(pc, tid, state.video_rid)
    {:noreply, %{state | video_pli_pending?: false}}
  end

  def handle_cast(:request_keyframe, state),
    do: {:noreply, %{state | video_pli_pending?: true}}

  def handle_cast(:close, state) do
    state = %{state | closing?: true}

    if state.reliable_open? do
      _ = send_nuance_event(state, Protocol.session_close_frame())
    end

    teardown(state, end_remote?: true)
    {:stop, :normal, state}
  end

  # -- HTTP session setup & event polling --

  @impl true
  def handle_info(:start_session, %{closing?: true} = state), do: {:noreply, state}

  def handle_info(:start_session, state) do
    with {:ok, token} <- mint_session_token(state),
         {:ok, conv_id} <- create_conversation(state, token) do
      parent = self()
      base_url = state.base_url

      task =
        spawn_link(fn ->
          poll_events_loop(parent, base_url, token, conv_id, 0, false, 0)
        end)

      {:noreply, %{state | session_token: token, conversation_id: conv_id, events_task: task}}
    else
      {:error, reason} ->
        Logger.warning("Nuance Live start failed: #{inspect(reason)}")
        send(state.parent, {:nuance_live_socket, {:error, reason}})
        {:noreply, state}
    end
  end

  def handle_info({:nuance_http_event, %{"type" => "preparing"}}, state) do
    send(state.parent, {:nuance_live_socket, {:status, "Preparing"}})
    {:noreply, state}
  end

  def handle_info(
        {:nuance_http_event, %{"type" => "admitted", "livekit_url" => url, "token" => lk_token}},
        %{closing?: false} = state
      )
      when is_binary(url) and is_binary(lk_token) do
    rtc_url = Signal.rtc_url(url, lk_token)

    case Signal.start_link(url: rtc_url, parent: self()) do
      {:ok, sig} ->
        {:noreply, %{state | admitted?: true, signal: sig}}

      {:error, reason} ->
        Logger.warning("Nuance Live LiveKit signal connect failed: #{inspect(reason)}")
        send(state.parent, {:nuance_live_socket, {:error, {:livekit_signal, reason}}})
        {:noreply, %{state | admitted?: true}}
    end
  end

  def handle_info({:nuance_http_event, %{"type" => "started"} = ev}, state) do
    send(state.parent, {:nuance_live_socket, {:conversation_started, ev["seconds_remaining"]}})
    {:noreply, state}
  end

  def handle_info({:nuance_http_event, %{"type" => "ended"} = ev}, state) do
    reason = ev["reason"] || "ended"
    send(state.parent, {:nuance_live_socket, {:conversation_ended, reason}})
    state = %{state | ended?: true}
    {:noreply, teardown(state, end_remote?: false)}
  end

  def handle_info({:nuance_http_event, _other}, state), do: {:noreply, state}

  def handle_info({:nuance_http_error, reason}, state) do
    Logger.warning("Nuance Live events poller failed: #{inspect(reason)}")
    send(state.parent, {:nuance_live_socket, {:disconnected, reason}})
    {:noreply, state}
  end

  # -- LiveKit Signal WebSocket events --

  def handle_info({:livekit_signal, :connected}, state), do: {:noreply, state}

  def handle_info({:livekit_signal, {:join, info}}, state) do
    ice_servers = normalize_ice_servers(info.ice_servers)

    ping_ms =
      if info.ping_interval > 0, do: info.ping_interval * 1_000, else: state.ping_interval_ms

    base_opts =
      [ice_servers: ice_servers]
      |> Keyword.merge(Application.get_env(:octoroom, :webrtc, []))
      |> Keyword.merge(state.webrtc_opts)

    {:ok, sub_pc} =
      PeerConnection.start_link(
        Keyword.merge(base_opts,
          audio_codecs: [:opus],
          video_codecs: Octoroom.Peer.WebRTC.default_video_codecs()
        )
      )

    camera? =
      Keyword.get(state.setup, :camera, false) or Keyword.get(state.setup, :camera_input, false)

    pub_video_codecs =
      if camera?, do: Octoroom.Peer.WebRTC.default_video_codecs(), else: []

    {:ok, pub_pc} =
      PeerConnection.start_link(
        Keyword.merge(base_opts, audio_codecs: [:opus], video_codecs: pub_video_codecs)
      )

    {:ok, reliable_dc} = PeerConnection.create_data_channel(pub_pc, "_reliable", ordered: true)

    {:ok, _lossy_dc} =
      PeerConnection.create_data_channel(pub_pc, "_lossy", ordered: true, max_retransmits: 0)

    stream_id = MediaStreamTrack.generate_stream_id()
    mic_track = MediaStreamTrack.new(:audio, [stream_id])
    {:ok, _tr} = PeerConnection.add_transceiver(pub_pc, mic_track, direction: :sendonly)

    if is_pid(state.signal) do
      Signal.send_proto(
        state.signal,
        Protobuf.encode_add_track(%{
          cid: to_string(mic_track.id),
          name: "microphone",
          type: :audio,
          source: :microphone,
          disable_red: true,
          stream: stream_id
        })
      )
    end

    pub_video_track_id =
      if camera? do
        cam_track = MediaStreamTrack.new(:video, [stream_id])
        {:ok, _tr} = PeerConnection.add_transceiver(pub_pc, cam_track, direction: :sendonly)

        if is_pid(state.signal) do
          Signal.send_proto(
            state.signal,
            Protobuf.encode_add_track(%{
              cid: to_string(cam_track.id),
              name: "camera",
              type: :video,
              source: :camera,
              width: 1280,
              height: 720,
              stream: stream_id
            })
          )
        end

        cam_track.id
      else
        nil
      end

    # Fallback in case track_published is delayed or fast_publish expects offer immediately.
    Process.send_after(self(), :ensure_pub_offer, 400)
    ping_timer = Process.send_after(self(), :livekit_ping, ping_ms)

    {:noreply,
     %{
       state
       | sub_pc: sub_pc,
         pub_pc: pub_pc,
         pub_track_id: mic_track.id,
         pub_video_track_id: pub_video_track_id,
         pub_video_codec: nil,
         pub_tracks_expected: if(camera?, do: 2, else: 1),
         pub_tracks_published: 0,
         reliable_ref: reliable_dc.ref,
         ping_interval_ms: ping_ms,
         ping_timer: ping_timer
     }}
  end

  def handle_info({:livekit_signal, {:track_published, _info}}, state) do
    published = state.pub_tracks_published + 1
    state = %{state | pub_tracks_published: published}

    if published >= state.pub_tracks_expected do
      {:noreply, maybe_send_pub_offer(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:ensure_pub_offer, state) do
    {:noreply, maybe_send_pub_offer(state)}
  end

  def handle_info({:livekit_signal, {:answer, %{sdp: sdp}}}, %{pub_pc: pc} = state)
      when is_pid(pc) and is_binary(sdp) do
    case PeerConnection.set_remote_description(pc, %SessionDescription{type: :answer, sdp: sdp}) do
      :ok ->
        flush_ice_candidates(pc, Enum.reverse(state.pub_pending_ice))
        Process.send_after(self(), {:end_of_candidates, :publisher}, 300)
        {:noreply, %{state | pub_remote_set?: true, pub_pending_ice: []}}

      {:error, reason} ->
        Logger.warning("Nuance Live pub set_remote_description failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:livekit_signal, {:offer, %{sdp: sdp, id: id}}}, %{sub_pc: pc} = state)
      when is_pid(pc) and is_binary(sdp) do
    with :ok <-
           PeerConnection.set_remote_description(pc, %SessionDescription{type: :offer, sdp: sdp}),
         {:ok, answer} <- PeerConnection.create_answer(pc),
         :ok <- PeerConnection.set_local_description(pc, answer) do
      flush_ice_candidates(pc, Enum.reverse(state.sub_pending_ice))

      if not state.sub_remote_set? do
        Process.send_after(self(), {:end_of_candidates, :subscriber}, 300)
      end

      if is_pid(state.signal) do
        Signal.send_proto(state.signal, Protobuf.encode_answer(answer.sdp, id))
      end

      {:noreply, %{state | sub_remote_set?: true, sub_pending_ice: []}}
    else
      {:error, reason} ->
        Logger.warning("Nuance Live sub answer_offer failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(
        {:livekit_signal, {:trickle, %{candidate_init: json, target: target, final: final}}},
        state
      ) do
    state =
      case parse_ice_candidate(json) do
        {:ok, candidate} -> add_remote_ice(state, target, candidate)
        :ignore -> state
      end

    state =
      if final do
        add_remote_ice(state, target, %ICECandidate{candidate: ""})
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:end_of_candidates, target}, state) do
    {:noreply, add_remote_ice(state, target, %ICECandidate{candidate: ""})}
  end

  def handle_info({:livekit_signal, {:leave, info}}, state) do
    Logger.info("Nuance Live LiveKit server requested leave: #{inspect(info)}")
    send(state.parent, {:nuance_live_socket, {:disconnected, {:livekit_leave, info.reason}}})
    {:noreply, state}
  end

  def handle_info({:livekit_signal, {:disconnected, reason}}, %{closing?: false} = state) do
    Logger.warning("Nuance Live LiveKit signal disconnected: #{inspect(reason)}")
    send(state.parent, {:nuance_live_socket, {:disconnected, reason}})
    {:noreply, %{state | signal: nil}}
  end

  def handle_info({:livekit_signal, {:pong_resp, _info}}, state), do: {:noreply, state}
  def handle_info({:livekit_signal, {:pong, _ts}}, state), do: {:noreply, state}

  def handle_info({:livekit_signal, {:subscription_response, %{err: 0}}}, state),
    do: {:noreply, state}

  def handle_info({:livekit_signal, {:subscription_response, info}}, state) do
    Logger.warning("Nuance Live LiveKit subscription error: #{inspect(info)}")
    {:noreply, state}
  end

  def handle_info({:livekit_signal, _other}, state), do: {:noreply, state}

  def handle_info(:livekit_ping, %{signal: sig, closing?: false} = state) when is_pid(sig) do
    Signal.send_proto(sig, Protobuf.encode_ping(System.system_time(:millisecond)))
    timer = Process.send_after(self(), :livekit_ping, state.ping_interval_ms)
    {:noreply, %{state | ping_timer: timer}}
  end

  def handle_info(:livekit_ping, state), do: {:noreply, %{state | ping_timer: nil}}

  # -- ExWebRTC events (publisher & subscriber PeerConnections) --

  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, %{pub_pc: pc} = state) do
    send_trickle(state.signal, candidate, :publisher)
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:ice_candidate, candidate}}, %{sub_pc: pc} = state) do
    send_trickle(state.signal, candidate, :subscriber)
    {:noreply, state}
  end

  def handle_info(
        {:ex_webrtc, pc, {:connection_state_change, :connected}},
        %{pub_pc: pc} = state
      ) do
    state = %{state | pub_connected?: true}
    send(state.parent, {:nuance_live_socket, :connected})

    if not is_nil(state.pub_video_track_id) do
      send(state.parent, {:nuance_live_socket, :camera_pli})
    end

    {:noreply, start_rtp_pacer(state)}
  end

  def handle_info(
        {:ex_webrtc, pc, {:rtcp, packets}},
        %{pub_pc: pc, pub_video_track_id: tid} = state
      )
      when not is_nil(tid) do
    if Enum.any?(packets, &match?({^tid, %ExRTCP.Packet.PayloadFeedback.PLI{}}, &1)) do
      send(state.parent, {:nuance_live_socket, :camera_pli})
    end

    {:noreply, state}
  end

  def handle_info(
        {:ex_webrtc, pc, {:connection_state_change, :connected}},
        %{sub_pc: pc} = state
      ) do
    if state.video_rtp_seen? and not is_nil(state.video_track_id) do
      PeerConnection.send_pli(pc, state.video_track_id, state.video_rid)
    end

    {:noreply, state}
  end

  def handle_info(
        {:ex_webrtc, pc, {:data_channel_state_change, ref, :open}},
        %{pub_pc: pc, reliable_ref: ref} = state
      ) do
    state = %{state | reliable_open?: true}

    state =
      Enum.reduce(Enum.reverse(state.pending_control), %{state | pending_control: []}, fn
        {:raw, topic, payload}, s ->
          send_user_packet(s, topic, payload)

        {:nuance, frame}, s ->
          send_nuance_event(s, frame)
      end)

    {:noreply, state}
  end

  def handle_info(
        {:ex_webrtc, pc, {:track, %MediaStreamTrack{id: id, kind: kind}}},
        %{
          sub_pc: pc
        } = state
      ) do
    state = put_in(state.sub_tracks[id], kind)

    state =
      if kind == :video do
        %{state | video_track_id: id, video_rtp_seen?: false, video_rid: nil}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:rtp, track_id, rid, packet}}, %{sub_pc: pc} = state) do
    {kind, state} = track_kind(state, track_id)

    case kind do
      :video ->
        state =
          if not state.video_rtp_seen? or packet.payload_type != state.video_pt do
            codec = resolve_video_codec(pc, track_id, packet.payload_type)

            if not state.video_rtp_seen? and state.video_pli_pending? do
              PeerConnection.send_pli(pc, track_id, rid)
            end

            %{
              state
              | video_track_id: track_id,
                video_rid: rid,
                video_rtp_seen?: true,
                video_pli_pending?: false,
                video_pt: packet.payload_type,
                video_codec: codec || state.video_codec
            }
          else
            state
          end

        send(state.parent, {:nuance_live_socket, {:video_rtp, packet, state.video_codec}})
        {:noreply, state}

      :audio ->
        {packets, timer, jitter} = JitterBuffer.insert(state.jitter, packet)

        {:noreply,
         %{state | jitter: jitter}
         |> set_jitter_timer(timer)
         |> decode_packets(packets)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:ex_webrtc, _pc, {:data, _ref, bin}}, state) when is_binary(bin) do
    received_at_s = System.system_time(:microsecond) / 1_000_000

    case Protobuf.decode_data_packet(bin) do
      {:ok, {:user, %{topic: topic, payload: payload}}} ->
        {:noreply, handle_topic_payload(state, topic, payload, received_at_s)}

      {:ok, {:stream_header, %{stream_id: sid, topic: topic, inline_content: inline}}} ->
        if is_binary(inline) do
          {:noreply, handle_topic_payload(state, topic, inline, received_at_s)}
        else
          {:noreply, put_in(state.streams[sid], %{topic: topic, chunks: []})}
        end

      {:ok, {:stream_chunk, %{stream_id: sid, chunk_index: idx, content: content}}} ->
        case Map.get(state.streams, sid) do
          %{chunks: chunks} = stream ->
            {:noreply, put_in(state.streams[sid], %{stream | chunks: [{idx, content} | chunks]})}

          nil ->
            {:noreply, state}
        end

      {:ok, {:stream_trailer, %{stream_id: sid}}} ->
        case Map.pop(state.streams, sid) do
          {%{topic: topic, chunks: chunks}, streams} ->
            payload =
              chunks
              |> Enum.sort_by(&elem(&1, 0))
              |> Enum.map_join(&elem(&1, 1))

            {:noreply,
             handle_topic_payload(%{state | streams: streams}, topic, payload, received_at_s)}

          {nil, _} ->
            {:noreply, state}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:timeout, _ref, :rtp_tick}, %{pub_connected?: true, pub_pc: pc} = state)
      when is_pid(pc) do
    {:noreply, send_rtp_tick(state)}
  end

  def handle_info({:timeout, _ref, :rtp_tick}, state), do: {:noreply, %{state | rtp_timer: nil}}

  def handle_info(:jitter_timeout, state) do
    {packets, timer, jitter} = JitterBuffer.handle_timeout(state.jitter)

    {:noreply,
     %{state | jitter: jitter, jitter_timer: nil}
     |> set_jitter_timer(timer)
     |> decode_packets(packets)}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if not state.closing? and state.reliable_open? do
      _ = send_nuance_event(state, Protocol.session_close_frame())
    end

    teardown(state, end_remote?: true)
    :ok
  end

  # -- HTTP helpers --

  defp mint_session_token(state) do
    body = Protocol.session_token_request(state.setup)

    case Req.post("#{state.base_url}/session-tokens",
           headers: [{"authorization", "Bearer #{state.api_key}"}],
           json: body,
           receive_timeout: @http_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: status, body: %{"token" => token} = resp}}
      when status in [200, 201] and is_binary(token) ->
        case resp["warnings"] do
          [_ | _] = warnings ->
            Logger.warning("Nuance Live session token warnings: #{inspect(warnings)}")

          _ ->
            :ok
        end

        {:ok, token}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:session_token_failed, status, resp_body}}

      {:error, reason} ->
        {:error, {:session_token_failed, reason}}
    end
  end

  defp create_conversation(state, session_token) do
    body = Protocol.conversation_request(state.setup)

    case Req.post("#{state.base_url}/conversation",
           headers: [{"authorization", "Bearer #{session_token}"}],
           json: body,
           receive_timeout: @http_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: status, body: %{"id" => conv_id}}}
      when status in [200, 201] and is_binary(conv_id) ->
        {:ok, conv_id}

      {:ok, %{status: status, body: resp_body}} ->
        {:error, {:conversation_failed, status, resp_body}}

      {:error, reason} ->
        {:error, {:conversation_failed, reason}}
    end
  end

  defp poll_events_loop(parent, base_url, token, conv_id, after_id, admitted?, errors) do
    url = "#{base_url}/conversation/#{conv_id}/events?after=#{after_id}"

    case Req.get(url,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: @poll_timeout_ms,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"events" => events}}} when is_list(events) ->
        {next_after, now_admitted?, ended?} =
          Enum.reduce(events, {after_id, admitted?, false}, fn ev, {last_id, adm?, done?} ->
            send(parent, {:nuance_http_event, ev})
            id = if is_integer(ev["id"]), do: ev["id"], else: last_id
            adm? = adm? or ev["type"] == "admitted"
            done? = done? or ev["type"] == "ended"
            {id, adm?, done?}
          end)

        unless ended? do
          poll_events_loop(parent, base_url, token, conv_id, next_after, now_admitted?, 0)
        end

      {:ok, %{status: status, body: body}} ->
        errors = errors + 1

        if not admitted? and errors >= @max_poll_errors do
          send(parent, {:nuance_http_error, {:http_status, status, body}})
        else
          Process.sleep(1_000)
          poll_events_loop(parent, base_url, token, conv_id, after_id, admitted?, errors)
        end

      {:error, reason} ->
        errors = errors + 1

        if not admitted? and errors >= @max_poll_errors do
          send(parent, {:nuance_http_error, reason})
        else
          Process.sleep(1_000)
          poll_events_loop(parent, base_url, token, conv_id, after_id, admitted?, errors)
        end
    end
  end

  defp end_remote_conversation(%{conversation_id: nil}), do: :ok
  defp end_remote_conversation(%{ended?: true}), do: :ok

  defp end_remote_conversation(%{admitted?: false} = state)
       when is_binary(state.session_token) do
    _ =
      Req.post("#{state.base_url}/conversation/#{state.conversation_id}/abandon",
        headers: [
          {"authorization", "Bearer #{state.session_token}"},
          {"content-length", "0"}
        ],
        body: "",
        receive_timeout: 5_000,
        retry: false
      )

    :ok
  end

  defp end_remote_conversation(state) do
    _ =
      Req.post("#{state.base_url}/conversation/#{state.conversation_id}/end",
        headers: [
          {"authorization", "Bearer #{state.api_key}"},
          {"content-length", "0"}
        ],
        body: "",
        receive_timeout: 5_000,
        retry: false
      )

    :ok
  end

  # -- LiveKit WebRTC helpers --

  defp maybe_send_pub_offer(%{pub_offer_sent?: true} = state), do: state
  defp maybe_send_pub_offer(%{pub_pc: nil} = state), do: state

  defp maybe_send_pub_offer(%{pub_pc: pc} = state) do
    with {:ok, offer} <- PeerConnection.create_offer(pc),
         :ok <- PeerConnection.set_local_description(pc, offer) do
      if is_pid(state.signal) do
        Signal.send_proto(state.signal, Protobuf.encode_offer(offer.sdp))
      end

      %{state | pub_offer_sent?: true}
    else
      {:error, reason} ->
        Logger.warning("Nuance Live pub create_offer failed: #{inspect(reason)}")
        state
    end
  end

  defp resolve_video_codec(pc, track_id, payload_type) do
    with transceivers when is_list(transceivers) <- PeerConnection.get_transceivers(pc),
         %{codecs: codecs} <-
           Enum.find(transceivers, &(&1.receiver.track && &1.receiver.track.id == track_id)),
         %{mime_type: mime} <- Enum.find(codecs, &(&1.payload_type == payload_type)) do
      case String.downcase(mime) do
        "video/vp8" -> :vp8
        "video/vp9" -> :vp9
        "video/h264" -> :h264
        "video/av1" -> :av1
        other -> other
      end
    else
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp normalize_ice_servers(servers) when is_list(servers) do
    Enum.flat_map(servers, fn server ->
      urls =
        server
        |> Map.get(:urls, [])
        |> Enum.filter(fn url ->
          String.starts_with?(url, "stun:") or String.starts_with?(url, "turn:")
        end)

      case urls do
        [] -> []
        urls -> [%{server | urls: urls}]
      end
    end)
  end

  defp parse_ice_candidate(""), do: :ignore

  defp parse_ice_candidate(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"candidate" => cand} = map} when is_binary(cand) and cand != "" ->
        {:ok,
         %ICECandidate{
           candidate: cand,
           sdp_mid: map["sdpMid"],
           sdp_m_line_index: map["sdpMLineIndex"]
         }}

      _ ->
        :ignore
    end
  end

  defp add_remote_ice(%{pub_pc: pc, pub_remote_set?: true} = state, :publisher, cand)
       when is_pid(pc) do
    PeerConnection.add_ice_candidate(pc, cand)
    state
  end

  defp add_remote_ice(state, :publisher, cand),
    do: %{state | pub_pending_ice: [cand | state.pub_pending_ice]}

  defp add_remote_ice(%{sub_pc: pc, sub_remote_set?: true} = state, :subscriber, cand)
       when is_pid(pc) do
    PeerConnection.add_ice_candidate(pc, cand)
    state
  end

  defp add_remote_ice(state, :subscriber, cand),
    do: %{state | sub_pending_ice: [cand | state.sub_pending_ice]}

  defp flush_ice_candidates(pc, candidates) do
    Enum.each(candidates, &PeerConnection.add_ice_candidate(pc, &1))
  end

  defp send_trickle(sig, %ICECandidate{} = cand, target) when is_pid(sig) do
    if is_binary(cand.candidate) and cand.candidate != "" do
      json =
        Jason.encode!(%{
          candidate: cand.candidate,
          sdpMid: cand.sdp_mid,
          sdpMLineIndex: cand.sdp_m_line_index
        })

      Signal.send_proto(sig, Protobuf.encode_trickle(json, target))
    end
  end

  defp send_trickle(_sig, _cand, _target), do: :ok

  defp track_kind(state, track_id) do
    case Map.get(state.sub_tracks, track_id) do
      nil ->
        found =
          if is_pid(state.sub_pc) do
            state.sub_pc
            |> PeerConnection.get_transceivers()
            |> Enum.find_value(fn tr ->
              if tr.receiver.track && tr.receiver.track.id == track_id, do: tr.kind
            end)
          end

        if found,
          do: {found, put_in(state.sub_tracks[track_id], found)},
          else: {nil, state}

      kind ->
        {kind, state}
    end
  end

  # -- DataChannel sending & receiving --

  defp handle_topic_payload(state, "clock-sync", payload, received_at_s) do
    case Protocol.handle_clock_sync(payload, received_at_s) do
      {:ok, pong_json} ->
        send_or_queue_raw(state, Protocol.clock_sync_topic(), pong_json)

      :ignore ->
        state
    end
  end

  defp handle_topic_payload(state, "nuance_live", payload, _received_at_s) do
    case Protocol.decode_packet(payload, state.parts) do
      {:ok, events, parts} ->
        Enum.each(events, &send(state.parent, {:nuance_live_socket, &1}))
        %{state | parts: parts}

      {:error, reason, parts} ->
        send(state.parent, {:nuance_live_socket, {:decode_error, reason}})
        %{state | parts: parts}
    end
  end

  defp handle_topic_payload(state, _topic, _payload, _received_at_s), do: state

  defp send_or_queue_nuance(%{reliable_open?: true} = state, frame),
    do: send_nuance_event(state, frame)

  defp send_or_queue_nuance(state, frame),
    do: %{state | pending_control: [{:nuance, frame} | state.pending_control]}

  defp send_or_queue_raw(%{reliable_open?: true} = state, topic, payload),
    do: send_user_packet(state, topic, payload)

  defp send_or_queue_raw(state, topic, payload),
    do: %{state | pending_control: [{:raw, topic, payload} | state.pending_control]}

  defp send_nuance_event(state, frame) do
    json = Jason.encode!(frame)

    if byte_size(json) <= Protocol.max_packet_bytes() do
      send_user_packet(state, Protocol.nuance_topic(), json)
    else
      stream_id = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

      packets = Protobuf.encode_text_stream(json, Protocol.nuance_topic(), stream_id)

      if is_pid(state.pub_pc) and state.reliable_ref != nil do
        Enum.each(packets, fn pkt ->
          PeerConnection.send_data(state.pub_pc, state.reliable_ref, pkt, :binary)
        end)
      end

      state
    end
  end

  defp send_user_packet(%{pub_pc: pc, reliable_ref: ref} = state, topic, payload)
       when is_pid(pc) and ref != nil do
    seq = state.data_seq + 1
    packet = Protobuf.encode_user_packet(payload, topic, kind: :reliable, sequence: seq)
    PeerConnection.send_data(pc, ref, packet, :binary)
    %{state | data_seq: seq}
  end

  defp send_user_packet(state, _topic, _payload), do: state

  # -- Teardown --

  defp teardown(state, opts) do
    if state.rtp_timer, do: :erlang.cancel_timer(state.rtp_timer)
    if state.jitter_timer, do: Process.cancel_timer(state.jitter_timer)
    if state.ping_timer, do: Process.cancel_timer(state.ping_timer)

    if is_pid(state.signal) do
      Signal.send_proto(state.signal, Protobuf.encode_leave())
      Signal.close(state.signal)
    end

    close_pc(state.pub_pc)
    close_pc(state.sub_pc)

    if is_pid(state.events_task) and Process.alive?(state.events_task) do
      Process.exit(state.events_task, :shutdown)
    end

    if Keyword.get(opts, :end_remote?, false) do
      end_remote_conversation(state)
    end

    %{
      state
      | signal: nil,
        ping_timer: nil,
        pub_pc: nil,
        sub_pc: nil,
        events_task: nil,
        pub_connected?: false,
        reliable_open?: false,
        rtp_timer: nil,
        jitter_timer: nil
    }
  end

  defp close_pc(pid) when is_pid(pid) do
    PeerConnection.close(pid)
  catch
    :exit, _ -> :ok
  end

  defp close_pc(_), do: :ok

  # -- Outbound Opus RTP pacer (20 ms frames, continuous silence when idle) --

  defp start_rtp_pacer(%{rtp_timer: nil} = state), do: send_rtp_tick(state)
  defp start_rtp_pacer(state), do: state

  defp send_rtp_tick(state) do
    {frame, queue, queued} =
      case :queue.out(state.in_queue) do
        {{:value, pcm}, q} -> {pcm, q, state.in_queued - 1}
        {:empty, q} -> {@silence, q, 0}
      end

    encoder = state.encoder || new_encoder()
    {:ok, payload} = Membrane.Opus.Encoder.Native.encode_packet(encoder, frame, @frame_samples)
    timestamp = rem(state.timestamp + @frame_samples, 4_294_967_296)

    packet =
      ExRTP.Packet.new(payload,
        sequence_number: state.seq,
        timestamp: timestamp,
        marker: state.spurt
      )

    PeerConnection.send_rtp(state.pub_pc, state.pub_track_id, packet)

    now = System.monotonic_time(:millisecond)
    next = if state.rtp_next, do: state.rtp_next + @frame_ms, else: now + @frame_ms
    next = if next < now - @max_lag_ms, do: now + @frame_ms, else: next
    timer = :erlang.start_timer(next, self(), :rtp_tick, abs: true)

    %{
      state
      | encoder: encoder,
        seq: rem(state.seq + 1, 65_536),
        timestamp: timestamp,
        spurt: false,
        in_queue: queue,
        in_queued: queued,
        rtp_next: next,
        rtp_timer: timer
    }
  end

  defp new_encoder, do: Membrane.Opus.Encoder.Native.create(48_000, 2, 2048, -1000, 3001)

  defp split_frames(<<frame::binary-size(@frame_bytes), rest::binary>>, acc),
    do: split_frames(rest, [frame | acc])

  defp split_frames(rest, acc), do: {Enum.reverse(acc), rest}

  defp enqueue_frames(queue, queued, []), do: {queue, queued}

  defp enqueue_frames(queue, queued, [frame | rest]) do
    {queue, queued} =
      if queued >= @max_queued_frames do
        {{:value, _dropped}, q} = :queue.out(queue)
        {:queue.in(frame, q), queued}
      else
        {:queue.in(frame, queue), queued + 1}
      end

    enqueue_frames(queue, queued, rest)
  end

  # -- Inbound Opus RTP decoder (24 kHz mono PCM16 + silence gate) --

  defp decode_packets(state, packets) do
    Enum.reduce(packets, state, fn packet, state ->
      case packet.payload do
        <<>> -> state
        payload -> decode_packet(state, payload)
      end
    end)
  end

  defp decode_packet(state, <<_config::5, stereo::1, _::2, _::binary>> = payload) do
    channels = stereo + 1

    decoder =
      Map.get_lazy(state.decoders, channels, fn ->
        Membrane.Opus.Decoder.Native.create(@out_rate, channels)
      end)

    state = put_in(state.decoders[channels], decoder)

    try do
      pcm = Membrane.Opus.Decoder.Native.decode_packet(decoder, payload)
      mono = Audio.rechannel(pcm, channels, 1)
      forward_speech(state, mono)
    catch
      _kind, _reason -> state
    end
  end

  defp forward_speech(state, <<>>), do: state

  defp forward_speech(state, pcm) do
    cond do
      PCM16.peak_abs(pcm) >= @silence_threshold ->
        send(state.parent, {:nuance_live_socket, {:audio, pcm, sample_rate: @out_rate}})
        %{state | hangover: @hangover_frames}

      state.hangover > 0 ->
        send(state.parent, {:nuance_live_socket, {:audio, pcm, sample_rate: @out_rate}})
        %{state | hangover: state.hangover - 1}

      true ->
        state
    end
  end

  defp set_jitter_timer(state, nil), do: state

  defp set_jitter_timer(state, ms) do
    if state.jitter_timer, do: Process.cancel_timer(state.jitter_timer)
    %{state | jitter_timer: Process.send_after(self(), :jitter_timeout, ms)}
  end
end
