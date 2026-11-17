defmodule Octoroom.Test.FakeCloudflare do
  @moduledoc false

  # An in-memory Cloudflare Realtime SFU. Models sessions, local and remote
  # tracks with mids, and the rule that a track with no packets can't be
  # pulled (`empty_track_error`). Local tracks start empty; `mark_live/3`
  # stands in for the first packet arriving. Every call is reported to the
  # test process as `{:cloudflare, call, args}`.
  #
  # Use `config(test_pid)` as a room server's `:cloudflare` option.

  @behaviour Octoroom.Cloudflare

  use Agent

  def start_link(test),
    do:
      Agent.start_link(fn ->
        %{test: test, sessions: %{}, live: MapSet.new(), n: 0, fail: %{}}
      end)

  def config(fake), do: %{client: __MODULE__, fake: fake}

  def mark_live(fake, session, track),
    do: Agent.update(fake, &%{&1 | live: MapSet.put(&1.live, {session, track})})

  @doc "Makes the next call to `call` return `{:error, reason}`."
  def fail_next(fake, call, reason), do: Agent.update(fake, &put_in(&1.fail[call], reason))

  def tracks(fake, session), do: Agent.get(fake, & &1.sessions[session].tracks)

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
  def new_adapters(%{fake: fake}, tracks), do: op(fake, :new_adapters, [tracks], &{{:ok, []}, &1})

  @impl true
  def close_adapters(%{fake: fake}, ids), do: op(fake, :close_adapters, [ids], &{:ok, &1})

  @impl true
  def session_state(%{fake: fake}, session),
    do: op(fake, :session_state, [session], &{{:ok, &1.sessions[session]}, &1})

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
