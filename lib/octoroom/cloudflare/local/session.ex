defmodule Octoroom.Cloudflare.Local.Session do
  @moduledoc false

  # One local SFU session: owns an `ExWebRTC.PeerConnection` and forwards RTP
  # packets (and video PLI feedback) between sessions via ETS.

  use GenServer, restart: :temporary

  alias ExRTCP.Packet.PayloadFeedback.PLI
  alias ExWebRTC.{MediaStreamTrack, PeerConnection, SessionDescription}

  @gather_timeout 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def push_tracks(pid, offer, tracks),
    do: GenServer.call(pid, {:push_tracks, offer, tracks}, 15_000)

  def pull_tracks(pid, tracks), do: GenServer.call(pid, {:pull_tracks, tracks}, 15_000)

  def renegotiate(pid, answer), do: GenServer.call(pid, {:renegotiate, answer}, 15_000)

  def close_tracks(pid, mids, offer),
    do: GenServer.call(pid, {:close_tracks, mids, offer}, 15_000)

  def session_state(pid), do: GenServer.call(pid, :session_state, 5_000)

  def stop(pid), do: GenServer.stop(pid, :normal)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    session_id = Keyword.fetch!(opts, :session_id)
    tables = Keyword.fetch!(opts, :tables)

    {:ok, pc} =
      PeerConnection.start_link(
        ice_servers: [],
        ice_aggressive_nomination: true,
        audio_codecs: [:opus],
        video_codecs: Octoroom.Peer.WebRTC.default_video_codecs()
      )

    :ets.insert(tables.sessions, {session_id, self(), pc})

    {:ok,
     %{
       id: session_id,
       sdp_id: Integer.to_string(System.unique_integer([:positive]) + 1_000_000_000),
       sdp_version: 1,
       tables: tables,
       pc: pc,
       connected?: false,
       disconnected?: false,
       # mid => %{track_name, track_id, kind}
       published: %{},
       # rx_track_id => track_name
       rx_by_track_id: %{},
       # rx_track_id => %{payload_type => mime_type} (video only)
       rx_codecs: %{},
       # {dest_pc, dest_track_id} => mime_type
       tx_codecs: %{},
       # mid => %{src_session, src_track_name, track_id, kind}
       pulled: %{},
       # tx_track_id => {src_session, src_track_name}
       tx_by_track_id: %{}
     }}
  end

  @impl true
  def handle_call(_req, _from, %{disconnected?: true} = state),
    do: {:reply, {:error, :disconnected}, state}

  def handle_call({:push_tracks, offer, tracks}, _from, state) do
    pc = state.pc

    with :ok <-
           PeerConnection.set_remote_description(pc, %SessionDescription{type: :offer, sdp: offer}),
         {:ok, answer} <- PeerConnection.create_answer(pc),
         :ok <- PeerConnection.set_local_description(pc, answer) do
      {sdp, state} = stamped_local_sdp(pc, state)
      transceivers = PeerConnection.get_transceivers(pc)
      state = register_published(state, tracks, transceivers)
      {:reply, {:ok, %{sdp: sdp}}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:pull_tracks, tracks}, _from, state) do
    pc = state.pc

    {entries, added} =
      Enum.map_reduce(tracks, [], fn %{session_id: src_sess, track_name: src_name}, added ->
        case :ets.lookup(state.tables.tracks, {src_sess, src_name}) do
          [{_, %{kind: kind}}] ->
            track = MediaStreamTrack.new(kind)
            {:ok, tr} = PeerConnection.add_transceiver(pc, track, direction: :sendonly)

            item = %{
              src_session: src_sess,
              src_track_name: src_name,
              tr_id: tr.id,
              track_id: track.id,
              kind: kind
            }

            {{:ok, item}, [item | added]}

          [] ->
            {{:error, %{session_id: src_sess, track_name: src_name, error: "empty_track_error"}},
             added}
        end
      end)

    if added == [] do
      pulled = Enum.map(entries, fn {:error, entry} -> entry end)
      {:reply, {:ok, %{sdp: nil, renegotiate: false, tracks: pulled}}, state}
    else
      with {:ok, offer} <- PeerConnection.create_offer(pc),
           :ok <- PeerConnection.set_local_description(pc, offer) do
        {sdp, state} = stamped_local_sdp(pc, state)
        by_tr_id = Map.new(PeerConnection.get_transceivers(pc), &{&1.id, &1})

        {pulled, state} =
          Enum.map_reduce(entries, state, fn
            {:error, entry}, state ->
              {entry, state}

            {:ok, item}, state ->
              mid = by_tr_id[item.tr_id].mid

              :ets.insert(
                state.tables.subs,
                {{item.src_session, item.src_track_name}, {state.id, pc, item.track_id, mid}}
              )

              pulled_entry = %{
                src_session: item.src_session,
                src_track_name: item.src_track_name,
                track_id: item.track_id,
                kind: item.kind
              }

              state = %{
                state
                | pulled: Map.put(state.pulled, mid, pulled_entry),
                  tx_by_track_id:
                    Map.put(
                      state.tx_by_track_id,
                      item.track_id,
                      {item.src_session, item.src_track_name}
                    )
              }

              {%{session_id: item.src_session, track_name: item.src_track_name, mid: mid}, state}
          end)

        {:reply, {:ok, %{sdp: sdp, renegotiate: true, tracks: pulled}}, state}
      else
        error -> {:reply, error, state}
      end
    end
  end

  def handle_call({:renegotiate, answer}, _from, state) do
    case PeerConnection.set_remote_description(state.pc, %SessionDescription{
           type: :answer,
           sdp: answer
         }) do
      :ok ->
        if state.connected?, do: schedule_video_plis(state)
        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:close_tracks, mids, offer}, _from, state) do
    state = unregister_mids(state, mids)
    pc = state.pc

    if is_binary(offer) do
      with :ok <-
             PeerConnection.set_remote_description(pc, %SessionDescription{
               type: :offer,
               sdp: offer
             }),
           {:ok, answer} <- PeerConnection.create_answer(pc),
           :ok <- PeerConnection.set_local_description(pc, answer) do
        {sdp, state} = stamped_local_sdp(pc, state)
        {:reply, {:ok, %{sdp: sdp}}, state}
      else
        error -> {:reply, error, state}
      end
    else
      for tr <- PeerConnection.get_transceivers(pc), tr.mid in mids, not tr.stopped do
        PeerConnection.stop_transceiver(pc, tr.id)
      end

      {:reply, {:ok, %{sdp: nil}}, state}
    end
  end

  def handle_call(:session_state, _from, state) do
    local_tracks =
      for {mid, pub} <- state.published do
        %{
          location: :local,
          track_name: pub.track_name,
          mid: mid,
          session_id: nil,
          status: :active
        }
      end

    remote_tracks =
      for {mid, sub} <- state.pulled do
        active? = :ets.lookup(state.tables.tracks, {sub.src_session, sub.src_track_name}) != []

        %{
          location: :remote,
          track_name: sub.src_track_name,
          mid: mid,
          session_id: sub.src_session,
          status: if(active?, do: :active, else: :inactive)
        }
      end

    {:reply, {:ok, %{tracks: Enum.sort_by(local_tracks ++ remote_tracks, & &1.mid)}}, state}
  end

  @impl true
  def handle_info({:ex_webrtc, pc, {:rtp, rx_track_id, _rid, packet}}, %{pc: pc} = state) do
    state =
      case Map.get(state.rx_by_track_id, rx_track_id) do
        nil ->
          state

        track_name ->
          mime = get_in(state.rx_codecs, [rx_track_id, packet.payload_type])

          Enum.reduce(
            :ets.lookup(state.tables.subs, {state.id, track_name}),
            state,
            fn {_, {_dest_session, dest_pc, dest_track_id, _dest_mid}}, acc ->
              acc =
                if is_binary(mime) and Map.get(acc.tx_codecs, {dest_pc, dest_track_id}) != mime do
                  Octoroom.Peer.WebRTC.select_sender_codec(dest_pc, dest_track_id, mime)
                  put_in(acc.tx_codecs[{dest_pc, dest_track_id}], mime)
                else
                  acc
                end

              PeerConnection.send_rtp(dest_pc, dest_track_id, packet)
              acc
            end
          )
      end

    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:rtcp, packets}}, %{pc: pc} = state) do
    for {out_track_id, %PLI{}} <- packets,
        {src_session, src_track_name} <- [Map.get(state.tx_by_track_id, out_track_id)],
        {_, %{pc: src_pc, track_id: src_track_id}} <-
          :ets.lookup(state.tables.tracks, {src_session, src_track_name}) do
      PeerConnection.send_pli(src_pc, src_track_id)
    end

    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, :connected}}, %{pc: pc} = state) do
    state = %{state | connected?: true}
    schedule_video_plis(state)
    {:noreply, state}
  end

  def handle_info(:send_video_plis, %{disconnected?: false} = state) do
    send_video_plis(state)
    {:noreply, state}
  end

  def handle_info({:ex_webrtc, pc, {:connection_state_change, status}}, %{pc: pc} = state)
      when status in [:failed, :closed] do
    cleanup(state)
    {:noreply, %{state | connected?: false, disconnected?: true}}
  end

  def handle_info({:EXIT, pc, _reason}, %{pc: pc} = state) do
    cleanup(state)
    {:stop, :normal, %{state | connected?: false, disconnected?: true}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)

    try do
      PeerConnection.close(state.pc)
    catch
      :exit, _ -> :ok
    end
  end

  ## Helpers

  defp register_published(state, tracks, transceivers) do
    by_mid = Map.new(transceivers, &{&1.mid, &1})

    Enum.reduce(tracks, state, fn %{mid: mid, track_name: track_name}, state ->
      case by_mid[mid] do
        %{kind: kind, codecs: codecs, receiver: %{track: %{id: rx_track_id}}} ->
          :ets.insert(
            state.tables.tracks,
            {{state.id, track_name},
             %{kind: kind, session_pid: self(), pc: state.pc, track_id: rx_track_id, mid: mid}}
          )

          rx_codecs =
            if kind == :video do
              codec_map =
                for c <- codecs,
                    not String.ends_with?(String.downcase(c.mime_type), "/rtx"),
                    into: %{} do
                  {c.payload_type, String.downcase(c.mime_type)}
                end

              Map.put(state.rx_codecs, rx_track_id, codec_map)
            else
              state.rx_codecs
            end

          %{
            state
            | published:
                Map.put(state.published, mid, %{
                  track_name: track_name,
                  track_id: rx_track_id,
                  kind: kind
                }),
              rx_by_track_id: Map.put(state.rx_by_track_id, rx_track_id, track_name),
              rx_codecs: rx_codecs
          }

        _other ->
          state
      end
    end)
  end

  defp unregister_mids(state, mids) do
    Enum.reduce(mids, state, fn mid, state ->
      state =
        case Map.pop(state.published, mid) do
          {nil, _} ->
            state

          {pub, published} ->
            :ets.delete(state.tables.tracks, {state.id, pub.track_name})

            %{
              state
              | published: published,
                rx_by_track_id: Map.delete(state.rx_by_track_id, pub.track_id)
            }
        end

      case Map.pop(state.pulled, mid) do
        {nil, _} ->
          state

        {sub, pulled} ->
          :ets.delete_object(
            state.tables.subs,
            {{sub.src_session, sub.src_track_name}, {state.id, state.pc, sub.track_id, mid}}
          )

          %{
            state
            | pulled: pulled,
              tx_by_track_id: Map.delete(state.tx_by_track_id, sub.track_id)
          }
      end
    end)
  end

  defp schedule_video_plis(state) do
    if Enum.any?(state.pulled, fn {_mid, sub} -> sub.kind == :video end) do
      send_video_plis(state)
      Process.send_after(self(), :send_video_plis, 400)
      Process.send_after(self(), :send_video_plis, 1_200)
    end
  end

  defp send_video_plis(state) do
    for {_mid, %{kind: :video, src_session: src_sess, src_track_name: src_name}} <- state.pulled,
        {_, %{pc: src_pc, track_id: src_track_id}} <-
          :ets.lookup(state.tables.tracks, {src_sess, src_name}) do
      PeerConnection.send_pli(src_pc, src_track_id)
    end
  end

  defp stamped_local_sdp(pc, state) do
    sdp =
      pc
      |> local_sdp()
      |> String.replace(
        ~r/^o=- \d+ \d+ /m,
        "o=- #{state.sdp_id} #{state.sdp_version} ",
        global: false
      )

    {sdp, %{state | sdp_version: state.sdp_version + 1}}
  end

  defp cleanup(state) do
    :ets.delete(state.tables.sessions, state.id)

    for {_mid, pub} <- state.published do
      :ets.delete(state.tables.tracks, {state.id, pub.track_name})
    end

    for {mid, sub} <- state.pulled do
      :ets.delete_object(
        state.tables.subs,
        {{sub.src_session, sub.src_track_name}, {state.id, state.pc, sub.track_id, mid}}
      )
    end
  end

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
end
