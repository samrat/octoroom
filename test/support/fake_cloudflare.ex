defmodule Octoroom.Test.FakeCloudflare do
  @moduledoc false

  # An in-memory Cloudflare Realtime SFU. Models sessions, local and remote
  # tracks with mids, and the rule that a track with no packets can't be
  # pulled (`empty_track_error`). Local tracks start empty; `mark_live/3`
  # stands in for the first packet arriving. Every call is reported to the
  # test process as `{:cloudflare, call, args}`.
  #
  # Media: a session whose peer is fake (`Octoroom.Test.FakePeerMedia`)
  # registers its process with `register_media/3`. `ingest/4` is a frame
  # pushed on one of a session's tracks: it makes the track live, is
  # reported to the test as `{:ingest, cf_track_name, frame}`, and goes on to
  # every registered session that pulled the track. `egress/4` sends a frame
  # to those sessions as if the track's publisher (say, a browser) had sent
  # it; each gets `{:fake_media, session, mid, frame}`.
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
          media: %{},
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

  @doc "Stops a track's packets."
  def mark_dead(fake, session, track),
    do: Agent.update(fake, &%{&1 | live: MapSet.delete(&1.live, {session, track})})

  @doc "Every session's id."
  def sessions(fake), do: Agent.get(fake, &Map.keys(&1.sessions))

  @doc "Media for `session` goes to `pid` (a fake peer)."
  def register_media(fake, session, pid),
    do: Agent.update(fake, &put_in(&1.media[session], pid))

  @doc "Sessions with a registered media process."
  def media_sessions(fake), do: Agent.get(fake, &Map.keys(&1.media))

  @doc "A frame pushed on the track at `mid` in `session`."
  def ingest(fake, session, mid, frame) do
    {test, track} =
      Agent.get_and_update(fake, fn s ->
        case get_in(s, [:sessions, session, :tracks, mid]) do
          %{name: name} -> {{s.test, name}, %{s | live: MapSet.put(s.live, {session, name})}}
          nil -> {{s.test, nil}, s}
        end
      end)

    if track do
      send(test, {:ingest, track, frame})
      egress(fake, session, track, frame)
    end

    :ok
  end

  @doc "Sends `frame` to every registered session that pulled `{session, track}`."
  def egress(fake, session, track, frame) do
    for {sub, %{tracks: tracks}} <- Agent.get(fake, & &1.sessions),
        pid = Agent.get(fake, & &1.media[sub]),
        {mid, %{name: ^track, remote: ^session}} <- tracks,
        do: send(pid, {:fake_media, sub, mid, frame})

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
          s = put_in(s.sessions[session].tracks[t.mid], %{name: t.track_name, remote: nil})
          # Pulls take mids after every pushed one.
          used =
            case Integer.parse(t.mid) do
              {n, ""} -> n
              _ -> 0
            end

          update_in(s.sessions[session].mid, &max(&1, used))
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
