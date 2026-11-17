defmodule Octoroom.Test.FakeCloudflare do
  @moduledoc false

  # An in-memory Cloudflare Realtime SFU. Models sessions, local and remote
  # tracks with mids, and the rule that a track with no packets can't be
  # pulled (`empty_track_error`). Local tracks start empty; `mark_live/3`
  # stands in for the first packet arriving. Every call is reported to the
  # test process as `{:cloudflare, call, args}`.
  #
  # WebSocket adapters: creating one makes the fake "dial" its endpoint, the
  # way Cloudflare would: a process looks up the adapter id's owner and sends
  # it `{:octoroom_adapter_socket, role, self()}`, as `Octoroom.Adapter.Socket`
  # does. An ingest adapter's first frame makes its track live; each frame
  # is reported to the test as `{:ingest, cf_track_name, frame}` and passed
  # on to egress adapters of that track. `egress/4` streams a frame to every
  # egress adapter of a track, as if its publisher had sent it.
  #
  # Use `config(test_pid)` as a room server's `:cloudflare` option.

  @behaviour Octoroom.Cloudflare

  use Agent

  def start_link(test),
    do:
      Agent.start_link(fn ->
        %{
          test: test,
          sessions: %{},
          live: MapSet.new(),
          n: 0,
          fail: %{},
          adapters: %{},
          disconnected: MapSet.new()
        }
      end)

  def config(fake), do: %{client: __MODULE__, fake: fake}

  def mark_live(fake, session, track),
    do: Agent.update(fake, &%{&1 | live: MapSet.put(&1.live, {session, track})})

  @doc "Makes the next call to `call` return `{:error, reason}`."
  def fail_next(fake, call, reason), do: Agent.update(fake, &put_in(&1.fail[call], reason))

  def tracks(fake, session), do: Agent.get(fake, & &1.sessions[session].tracks)

  @doc "The session's peer connection closed: its tracks stop, and reads say so."
  def disconnect(fake, session) do
    Agent.update(fake, fn s ->
      live = MapSet.reject(s.live, fn {sess, _} -> sess == session end)
      %{s | live: live, disconnected: MapSet.put(s.disconnected, session)}
    end)
  end

  @doc "Stops a track's packets, e.g. an ingest adapter's socket dropping."
  def mark_dead(fake, session, track),
    do: Agent.update(fake, &%{&1 | live: MapSet.delete(&1.live, {session, track})})

  @doc "Every session's id."
  def sessions(fake), do: Agent.get(fake, &Map.keys(&1.sessions))

  @doc "Open adapters: adapter id => `%{role, session_id, track_name}`."
  def adapters(fake),
    do: Agent.get(fake, &Map.new(&1.adapters, fn {id, a} -> {id, Map.delete(a, :pid)} end))

  @doc "Sends `frame` to every egress adapter of `{session, track}`."
  def egress(fake, session, track, frame) do
    for {_, %{role: :egress, session_id: ^session, track_name: ^track, pid: pid}} <-
          Agent.get(fake, & &1.adapters),
        do: send(pid, {:frame, frame})

    :ok
  end

  @impl true
  def new_session(%{fake: fake}) do
    op(fake, :new_session, [], fn s ->
      {id, s} = next(s, "session")
      {{:ok, id}, put_in(s.sessions[id], %{tracks: %{}, mid: 0})}
    end)
  end

  @impl true
  def push_tracks(%{fake: fake}, session, offer, tracks) do
    op(fake, :push_tracks, [session, offer, tracks], fn s ->
      s =
        Enum.reduce(tracks, s, fn t, s ->
          put_in(s.sessions[session].tracks[t.mid], %{name: t.track_name, remote: nil})
        end)

      {{:ok, %{sdp: "answer:#{session}"}}, s}
    end)
  end

  @impl true
  def pull_tracks(%{fake: fake}, session, tracks) do
    op(fake, :pull_tracks, [session, tracks], fn s ->
      {pulled, s} =
        Enum.map_reduce(tracks, s, fn t, s ->
          base = %{session_id: t.session_id, track_name: t.track_name}

          if MapSet.member?(s.live, {t.session_id, t.track_name}) do
            mid = Integer.to_string(s.sessions[session].mid + 1)
            s = put_in(s.sessions[session].mid, s.sessions[session].mid + 1)

            s =
              put_in(s.sessions[session].tracks[mid], %{name: t.track_name, remote: t.session_id})

            {Map.put(base, :mid, mid), s}
          else
            {Map.put(base, :error, "empty_track_error"), s}
          end
        end)

      {offer, s} = next(s, "offer")

      {{:ok,
        %{sdp: offer, renegotiate: Enum.any?(pulled, &Map.has_key?(&1, :mid)), tracks: pulled}},
       s}
    end)
  end

  @impl true
  def renegotiate(%{fake: fake}, session, answer),
    do: op(fake, :renegotiate, [session, answer], &{:ok, &1})

  @impl true
  def close_tracks(%{fake: fake}, session, mids, offer) do
    op(fake, :close_tracks, [session, mids, offer], fn s ->
      s = update_in(s.sessions[session].tracks, &Map.drop(&1, mids))
      {{:ok, %{sdp: offer && "answer:#{session}"}}, s}
    end)
  end

  @impl true
  def new_adapters(%{fake: fake}, tracks) do
    result =
      op(fake, :new_adapters, [tracks], fn s ->
        Enum.map_reduce(tracks, s, fn t, s ->
          {id, s} = next(s, "adapter")

          {adapter, s} =
            case t.location do
              "local" ->
                {session, s} = next(s, "adapter-session")
                s = put_in(s.sessions[session], %{tracks: %{}, mid: 0})
                {%{role: :ingest, session_id: session, track_name: t.trackName}, s}

              "remote" ->
                {%{role: :egress, session_id: t.sessionId, track_name: t.trackName}, s}
            end

          adapter = Map.put(adapter, :endpoint, t.endpoint)
          {{id, adapter}, put_in(s.adapters[id], adapter)}
        end)
        |> then(fn {created, s} -> {{:ok, created}, s} end)
      end)

    case result do
      {:ok, created} ->
        for {id, adapter} <- created do
          pid = spawn(fn -> dial(fake, adapter) end)

          Agent.update(fake, fn s ->
            if s.adapters[id], do: put_in(s.adapters[id][:pid], pid), else: s
          end)
        end

        {:ok, for({id, a} <- created, do: %{adapter_id: id, session_id: a.session_id})}

      error ->
        error
    end
  end

  @impl true
  def close_adapters(%{fake: fake}, ids) do
    op(fake, :close_adapters, [ids], fn s ->
      for id <- ids, pid = get_in(s.adapters, [id, :pid]), do: Process.exit(pid, :kill)
      {:ok, %{s | adapters: Map.drop(s.adapters, ids)}}
    end)
  end

  # Plays Cloudflare's end of one adapter's WebSocket.
  defp dial(fake, %{role: role, endpoint: endpoint} = adapter) do
    ws_id = endpoint |> String.split("/") |> List.last()

    case Octoroom.Adapter.lookup(role, ws_id) do
      nil ->
        :ok

      owner ->
        ref = Process.monitor(owner)
        send(owner, {:octoroom_adapter_socket, role, self()})
        socket_loop(fake, adapter, owner, ref)
    end
  end

  defp socket_loop(fake, adapter, owner, ref) do
    receive do
      # Ingest: a frame from the outlet.
      {:octoroom_pcm, frame} ->
        key = {adapter.session_id, adapter.track_name}

        test =
          Agent.get_and_update(fake, fn s -> {s.test, %{s | live: MapSet.put(s.live, key)}} end)

        send(test, {:ingest, adapter.track_name, frame})
        egress(fake, adapter.session_id, adapter.track_name, frame)
        socket_loop(fake, adapter, owner, ref)

      # Egress: a frame from the track's publisher.
      {:frame, frame} ->
        send(owner, {:octoroom_pcm, self(), frame})
        socket_loop(fake, adapter, owner, ref)

      {:DOWN, ^ref, :process, _, _} ->
        :ok
    end
  end

  @impl true
  def session_state(%{fake: fake}, session) do
    op(fake, :session_state, [session], fn s ->
      cond do
        MapSet.member?(s.disconnected, session) ->
          {{:error, :disconnected}, s}

        sess = s.sessions[session] ->
          tracks =
            for {mid, t} <- Enum.sort(sess.tracks) do
              source = t.remote || session

              %{
                location: if(t.remote, do: :remote, else: :local),
                track_name: t.name,
                mid: mid,
                session_id: t.remote,
                status: if(MapSet.member?(s.live, {source, t.name}), do: :active, else: :inactive)
              }
            end

          {{:ok, %{tracks: tracks}}, s}

        true ->
          {{:error, {:cloudflare, "/sessions/#{session}", 404, "not found"}}, s}
      end
    end)
  end

  defp op(fake, call, args, fun) do
    Agent.get_and_update(fake, fn s ->
      send(s.test, {:cloudflare, call, args})

      case Map.pop(s.fail, call) do
        {nil, _} -> fun.(s)
        {reason, fail} -> {{:error, reason}, %{s | fail: fail}}
      end
    end)
  end

  defp next(s, prefix), do: {"#{prefix}-#{s.n + 1}", %{s | n: s.n + 1}}
end
