defmodule Octoroom.Peer.WebRTC do
  @moduledoc false

  # `Octoroom.Peer.Media` over an `ex_webrtc` peer connection to Cloudflare.
  #
  # Cloudflare's SFU is ICE-lite with public addresses, so this side is the
  # controlling agent and opens the connection: host candidates are enough
  # (no STUN), and replies come back through the same NAT mapping. Aggressive
  # nomination connects on the first successful check; regular nomination
  # took ~12 s in Subvocal's spike. Extra `ExWebRTC.PeerConnection` options
  # (such as an ICE IP filter on Fly.io) come from
  # `config :octoroom, :webrtc, [...]`.
  #
  # Two things Cloudflare does that ex_webrtc doesn't expect (found
  # 2026-11-17):
  #
  #   * When a session's first negotiation is Cloudflare's offer (a worker
  #     whose first operation is a pull), applying the offer starts ICE
  #     checks at once, before Cloudflare has our answer. Those checks fail
  #     and the connection never recovers. So the offer's candidates are held
  #     back until `renegotiated/1`.
  #   * Once every m-line is rejected, Cloudflare's answer has no
  #     `a=group:BUNDLE` line, which ex_webrtc refuses
  #     (`:missing_bundle_group`). An empty one is put back.

  @behaviour Octoroom.Peer.Media

  alias ExRTCP.Packet.PayloadFeedback.PLI

  alias ExWebRTC.{
    ICECandidate,
    MediaStreamTrack,
    PeerConnection,
    RTPCodecParameters,
    SessionDescription
  }

  alias ExWebRTC.PeerConnection.Configuration

  @gather_timeout 5_000

  @doc false
  def default_video_codecs do
    vp9 = [
      %RTPCodecParameters{
        payload_type: 100,
        mime_type: "video/VP9",
        clock_rate: 90_000,
        sdp_fmtp_line: %ExSDP.Attribute.FMTP{pt: 100, profile_id: 0}
      },
      %RTPCodecParameters{
        payload_type: 102,
        mime_type: "video/VP9",
        clock_rate: 90_000,
        sdp_fmtp_line: %ExSDP.Attribute.FMTP{pt: 102, profile_id: 1}
      }
    ]

    Configuration.default_video_codecs() ++ vp9
  end

  @doc false
  def select_sender_codec(pc, track_id, codec) when is_pid(pc) and not is_nil(codec) do
    target_mime = normalize_video_mime(codec)

    with transceivers when is_list(transceivers) <- PeerConnection.get_transceivers(pc),
         %{sender: %{id: sender_id}, codecs: codecs} <-
           Enum.find(transceivers, &(&1.sender.track && &1.sender.track.id == track_id)),
         %RTPCodecParameters{} = chosen <-
           Enum.find(codecs, &(String.downcase(&1.mime_type) == target_mime)) do
      PeerConnection.set_sender_codec(pc, sender_id, chosen)
    else
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  def select_sender_codec(_pc, _track_id, _codec), do: :ok

  defp normalize_video_mime(mime) when is_binary(mime) do
    down = String.downcase(mime)
    if String.contains?(down, "/"), do: down, else: "video/#{down}"
  end

  defp normalize_video_mime(codec) when is_atom(codec), do: "video/#{codec}"

  defp video_codec_atom(mime) when is_binary(mime) do
    case String.downcase(mime) do
      "video/vp8" -> :vp8
      "video/vp9" -> :vp9
      "video/h264" -> :h264
      "video/av1" -> :av1
      other -> other
    end
  end

  @impl true
  def init(_opts) do
    opts =
      [
        ice_servers: [],
        ice_aggressive_nomination: true,
        audio_codecs: [:opus],
        video_codecs: default_video_codecs()
      ]
      |> Keyword.merge(Application.get_env(:octoroom, :webrtc, []))

    {:ok, pc} = PeerConnection.start_link(opts)
    {:ok, %{pc: pc, connected: false, held: [], rx_codecs: %{}}}
  end

  @impl true
  def session_created(state, _session_id), do: state

  @impl true
  def offer_sendonly(state, n) when is_integer(n) and n > 0,
    do: offer_sendonly(state, List.duplicate(:audio, n))

  def offer_sendonly(%{pc: pc} = state, kinds) when is_list(kinds) and kinds != [] do
    tracks =
      for kind <- kinds do
        track = MediaStreamTrack.new(kind)
        {:ok, _} = PeerConnection.add_transceiver(pc, track, direction: :sendonly)
        track
      end

    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    sdp = local_sdp(pc)
    transceivers = PeerConnection.get_transceivers(pc)

    slots =
      for track <- tracks do
        tr = Enum.find(transceivers, &(&1.sender.track && &1.sender.track.id == track.id))
        %{mid: tr.mid, sink: {:rtp, pc, track.id}, track_id: track.id}
      end

    {:ok, sdp, slots, state}
  end

  @impl true
  def apply_answer(%{pc: pc} = state, sdp) do
    case PeerConnection.set_remote_description(pc, %SessionDescription{
           type: :answer,
           sdp: ensure_bundle(sdp)
         }) do
      :ok -> {:ok, state}
      error -> error
    end
  end

  @impl true
  def answer_offer(%{pc: pc} = state, sdp) do
    # Once connected, the candidates are known already (ex_webrtc warns on
    # every repeat); before that, they wait for `renegotiated/1`.
    held = if state.connected, do: [], else: candidates(sdp)
    offer = %SessionDescription{type: :offer, sdp: strip_candidates(sdp)}

    with :ok <- PeerConnection.set_remote_description(pc, offer),
         {:ok, answer} <- PeerConnection.create_answer(pc),
         :ok <- PeerConnection.set_local_description(pc, answer) do
      answer = local_sdp(pc)

      transceivers = PeerConnection.get_transceivers(pc)

      refs =
        for tr <- transceivers,
            tr.mid != nil,
            tr.receiver.track,
            into: %{} do
          {tr.mid, tr.receiver.track.id}
        end

      rx_codecs =
        for tr <- transceivers,
            tr.kind == :video,
            tr.receiver.track,
            into: state.rx_codecs do
          map =
            for c <- tr.codecs,
                not String.ends_with?(String.downcase(c.mime_type), "/rtx"),
                into: %{} do
              {c.payload_type, video_codec_atom(c.mime_type)}
            end

          {tr.receiver.track.id, map}
        end

      {:ok, answer, refs, %{state | held: held, rx_codecs: rx_codecs}}
    end
  end

  @impl true
  def renegotiated(%{held: []} = state), do: state

  def renegotiated(%{pc: pc, held: held} = state) do
    for c <- held do
      PeerConnection.add_ice_candidate(pc, %ICECandidate{
        candidate: c,
        sdp_mid: "0",
        sdp_m_line_index: 0
      })
    end

    %{state | held: []}
  end

  @impl true
  def stop_and_offer(%{pc: pc} = state, mids) do
    for tr <- PeerConnection.get_transceivers(pc), tr.mid in mids do
      :ok = PeerConnection.stop_transceiver(pc, tr.id)
    end

    {:ok, offer} = PeerConnection.create_offer(pc)
    :ok = PeerConnection.set_local_description(pc, offer)
    {:ok, local_sdp(pc), state}
  end

  @impl true
  def send_pli(%{pc: pc} = state, track_id) when is_pid(pc) and not is_nil(track_id) do
    PeerConnection.send_pli(pc, track_id)
    state
  catch
    :exit, _ -> state
  end

  def send_pli(state, _track_id), do: state

  @impl true
  def handle_info({:ex_webrtc, pc, {:rtp, track_id, _rid, packet}}, %{pc: pc} = state) do
    case Map.get(state.rx_codecs, track_id) do
      nil -> {:input, track_id, {:rtp, packet}}
      codecs -> {:input, track_id, {:video_rtp, packet, Map.get(codecs, packet.payload_type)}}
    end
  end

  def handle_info({:ex_webrtc, pc, {:rtcp, packets}}, %{pc: pc} = state) do
    case for({track_id, %PLI{}} <- packets, do: track_id) |> Enum.uniq() do
      [] -> {:ignore, state}
      track_ids -> {:pli, track_ids, state}
    end
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = state),
    do: {:connected, %{state | connected: true}}

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :failed}}, %{pc: pc} = state),
    do: {:failed, state}

  def handle_info(_message, state), do: {:ignore, state}

  @impl true
  def close(%{pc: pc}) do
    PeerConnection.close(pc)
  catch
    :exit, _ -> :ok
  end

  # Cloudflare takes a complete SDP: no trickle ICE.
  defp local_sdp(pc) do
    if PeerConnection.get_ice_gathering_state(pc) != :complete do
      receive do
        {:ex_webrtc, ^pc, {:ice_gathering_state_change, :complete}} -> :ok
      after
        @gather_timeout -> :ok
      end
    end

    PeerConnection.get_local_description(pc).sdp
  end

  defp lines(sdp), do: String.split(sdp, "\r\n")

  defp strip_candidates(sdp),
    do:
      sdp |> lines() |> Enum.reject(&String.starts_with?(&1, "a=candidate:")) |> Enum.join("\r\n")

  defp candidates(sdp),
    do: for("a=" <> c <- lines(sdp), String.starts_with?(c, "candidate:"), do: c) |> Enum.uniq()

  defp ensure_bundle(sdp) do
    if String.contains?(sdp, "a=group:BUNDLE"),
      do: sdp,
      else: String.replace(sdp, "t=0 0\r\n", "t=0 0\r\na=group:BUNDLE\r\n", global: false)
  end
end
