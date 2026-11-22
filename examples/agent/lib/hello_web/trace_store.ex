defmodule HelloWeb.TraceStore do
  @moduledoc """
  Collects `:telemetry` events from `Octoroom` and `Octoroom.Agent` into
  grouped voice-turn waterfalls and room-join waterfalls for
  `HelloWeb.OctoroomDashboardPage`.
  """
  use GenServer

  @max_calls 25
  @max_utterances 100
  @max_joins 50
  @utterance_group_window_ms 1_500.0
  @join_group_window_ms 10_000.0
  @topic "octoroom:traces"

  def topic, do: @topic
  def room_topic(room_id), do: "octoroom:room_spans:#{room_id}"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(_opts) do
    events = Octoroom.Telemetry.events() ++ Octoroom.Agent.Telemetry.events()
    :telemetry.attach_many(__MODULE__, events, &__MODULE__.handle_telemetry/4, self())

    {:ok, fresh_state()}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(__MODULE__)
    :ok
  end

  @doc false
  def handle_telemetry(event, measurements, metadata, pid) do
    if relevant?(event) do
      now_ms = System.monotonic_time(:microsecond) / 1_000.0
      wall_at = DateTime.utc_now()
      GenServer.cast(pid, {:event, event, measurements, metadata, now_ms, wall_at})
    end
  end

  defp relevant?([:octoroom_agent, :processor, :async, status])
       when status in [:stop, :exception],
       do: true

  defp relevant?([:octoroom_agent, :tool, :call, status]) when status in [:stop, :exception],
    do: true

  defp relevant?([:octoroom_agent, :turn, _]), do: true
  defp relevant?([:octoroom_agent, :live, :session]), do: true
  defp relevant?([:octoroom_agent, :live, :response, :stop]), do: true
  defp relevant?([:octoroom_agent, :pipeline, :interruption]), do: true

  defp relevant?([:octoroom, :room, ev]) when ev in [:start, :stop], do: true

  defp relevant?([:octoroom, :participant, ev])
       when ev in [:join, :connected, :first_pull],
       do: true

  defp relevant?([:octoroom, :cloudflare, :request]), do: true
  defp relevant?([:octoroom, :peer, :connect]), do: true
  defp relevant?([:octoroom, :outlet, :live]), do: true
  defp relevant?([:octoroom, :pull, :stop]), do: true
  defp relevant?([:octoroom, :failure]), do: true
  defp relevant?(_), do: false

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, %{calls: state.calls, utterances: state.utterances, joins: state.joins}, state}
  end

  def handle_call(:clear, _from, _state) do
    broadcast()
    {:reply, :ok, fresh_state()}
  end

  @impl true
  def handle_cast({:event, event, measurements, metadata, now_ms, wall_at}, state) do
    state = record(event, measurements, metadata, now_ms, wall_at, state)
    broadcast()
    {:noreply, state}
  end

  defp fresh_state do
    %{
      seq: 0,
      calls: [],
      # room_id => call_id
      active_call: %{},
      utterances: [],
      joins: [],
      # {room_id, agent_id, input} => [span, ...]
      pending_decisions: %{},
      # {room_id, agent_id} => [span, ...] for preemptive LLM spans finished before :decided
      pending_preemptive: %{},
      # {room_id, agent_id} => utterance_id
      active_utterance: %{},
      # {room_id, agent_id, turn_id} => utterance_id
      turn_utterance: %{}
    }
  end

  defp broadcast do
    Phoenix.PubSub.broadcast(Hello.PubSub, @topic, :traces_updated)
  end

  defp broadcast_room_spans(nil, _agent_id, _spans, _now_ms), do: :ok
  defp broadcast_room_spans(_room_id, _agent_id, [], _now_ms), do: :ok

  defp broadcast_room_spans(room_id, agent_id, spans, now_ms) do
    payloads =
      for span <- spans do
        %{
          id: span.id,
          agent: agent_id,
          kind: Atom.to_string(span.kind),
          label: span.label,
          ago_start_ms: Float.round(max(now_ms - span.start_ms, 0.0), 1),
          ago_end_ms: Float.round(max(now_ms - span.end_ms, 0.0), 1),
          duration_ms: Float.round(span.duration_ms * 1.0, 1),
          first_output_ms:
            if(is_number(span[:first_output_ms]), do: Float.round(span.first_output_ms * 1.0, 1)),
          status: Atom.to_string(span.status || :ok)
        }
      end

    Phoenix.PubSub.broadcast(Hello.PubSub, room_topic(room_id), {:timeline_spans, payloads})
  end

  # -- Room lifecycle (calls) --

  defp record([:octoroom, :room, :start], _m, meta, now_ms, wall_at, state) do
    room_id = meta[:room_id] || "unknown"
    state = end_active_call(room_id, now_ms, wall_at, state)
    {_call_id, state} = start_call(room_id, meta[:run], now_ms, wall_at, state)
    state
  end

  defp record([:octoroom, :room, :stop], _m, meta, now_ms, wall_at, state) do
    room_id = meta[:room_id] || "unknown"
    end_active_call(room_id, now_ms, wall_at, state)
  end

  # -- Agent turn events --

  defp record(
         [:octoroom_agent, :processor, :async, status],
         m,
         %{processor: :decisions} = meta,
         now_ms,
         _wall_at,
         state
       )
       when status in [:stop, :exception] do
    {span, state} = build_async_span(status, m, meta, now_ms, state)
    key = {meta[:room_id], meta[:agent_id], meta[:input]}
    pending = Map.update(state.pending_decisions, key, [span], &Enum.take([span | &1], 3))
    %{state | pending_decisions: pending}
  end

  defp record(
         [:octoroom_agent, :turn, :decided],
         m,
         meta,
         now_ms,
         wall_at,
         state
       ) do
    room_id = meta[:room_id]
    agent_id = meta[:agent_id]
    input = meta[:input]
    speech_to_decided = (m[:speech_to_decided_ms] || 0) * 1.0
    speech_end_ms = now_ms - speech_to_decided

    key = {room_id, agent_id, input}
    {decision_span, pending} = pop_recent_decision(state.pending_decisions, key, now_ms)
    state = %{state | pending_decisions: pending}

    {front_spans, state} =
      build_front_spans(speech_end_ms, now_ms, speech_to_decided, decision_span, meta, state)

    {preemptive_span, pending_preemptive} =
      pop_recent_decision(state.pending_preemptive, {room_id, agent_id}, now_ms)

    state = %{state | pending_preemptive: pending_preemptive}
    initial_spans = front_spans ++ List.wrap(preemptive_span)

    {call_id, state} = ensure_call(room_id, now_ms, wall_at, state)

    {utterance_id, state} =
      find_or_create_utterance(
        call_id,
        room_id,
        input,
        meta[:speaker],
        meta[:text],
        speech_end_ms,
        now_ms,
        wall_at,
        meta[:why] == :typed,
        state
      )

    state =
      update_utterance(state, utterance_id, fn u ->
        lane =
          u.lanes
          |> Map.get(agent_id, new_lane(agent_id))
          |> Map.merge(%{
            outcome: meta[:outcome],
            why: meta[:why],
            decision: meta[:decision]
          })
          |> append_spans(initial_spans)

        u
        |> put_in([:lanes, agent_id], lane)
        |> maybe_fill_text(meta[:text])
        |> maybe_fill_speaker(meta[:speaker])
        |> recompute_bounds()
      end)

    broadcast_room_spans(room_id, agent_id, initial_spans, now_ms)
    put_in(state.active_utterance[{room_id, agent_id}], utterance_id)
  end

  defp record(
         [:octoroom_agent, :turn, :floor_wait],
         m,
         meta,
         now_ms,
         _wall_at,
         state
       ) do
    room_id = meta[:room_id]
    agent_id = meta[:agent_id]

    case Map.get(state.active_utterance, {room_id, agent_id}) do
      nil ->
        state

      utterance_id ->
        dur = (m[:duration_ms] || 0) * 1.0
        {span_id, state} = next_id(state)

        span = %{
          id: span_id,
          kind: :floor_wait,
          label: "floor wait",
          start_ms: now_ms - dur,
          end_ms: now_ms,
          duration_ms: dur,
          first_output_ms: nil,
          status: if(meta[:outcome] == :yielded, do: :yielded, else: :ok),
          meta: %{outcome: meta[:outcome], duration_ms: round(dur)}
        }

        broadcast_room_spans(room_id, agent_id, [span], now_ms)

        update_utterance(state, utterance_id, fn u ->
          lane =
            u.lanes
            |> Map.get(agent_id, new_lane(agent_id))
            |> append_spans([span])

          u |> put_in([:lanes, agent_id], lane) |> recompute_bounds()
        end)
    end
  end

  # A preemptive LLM task that finished or was cancelled before a turn committed
  # has no `turn_id`: hold `:ok` spans for the upcoming `:decided` event and drop
  # abandoned cancellations so they never attach to the previous utterance.
  defp record(
         [:octoroom_agent, :processor, :async, status],
         m,
         %{preemptive: true, turn_id: nil} = meta,
         now_ms,
         _wall_at,
         state
       )
       when status in [:stop, :exception] do
    if status == :stop and meta[:status] == :ok do
      {span, state} = build_async_span(status, m, meta, now_ms, state)
      key = {meta[:room_id], meta[:agent_id]}
      pending = Map.update(state.pending_preemptive, key, [span], &Enum.take([span | &1], 3))
      %{state | pending_preemptive: pending}
    else
      state
    end
  end

  defp record(
         [:octoroom_agent, :processor, :async, status],
         m,
         meta,
         now_ms,
         wall_at,
         state
       )
       when status in [:stop, :exception] do
    {span, state} = build_async_span(status, m, meta, now_ms, state)
    broadcast_room_spans(meta[:room_id], meta[:agent_id], [span], now_ms)
    attach_backend_span(meta[:room_id], meta[:agent_id], meta[:turn_id], span, wall_at, state)
  end

  defp record(
         [:octoroom_agent, :tool, :call, status],
         m,
         meta,
         now_ms,
         wall_at,
         state
       )
       when status in [:stop, :exception] do
    dur = native_to_ms(m[:duration] || 0)
    {span_id, state} = next_id(state)

    span_status =
      cond do
        status == :exception -> :error
        meta[:result] == :ok -> :ok
        true -> :error
      end

    span = %{
      id: span_id,
      kind: :tool,
      label: "tool:#{meta[:tool]}",
      start_ms: now_ms - dur,
      end_ms: now_ms,
      duration_ms: dur,
      first_output_ms: nil,
      status: span_status,
      meta: compact_map(%{tool: meta[:tool], result: meta[:result], reason: meta[:reason]})
    }

    broadcast_room_spans(meta[:room_id], meta[:agent_id], [span], now_ms)
    attach_backend_span(meta[:room_id], meta[:agent_id], nil, span, wall_at, state)
  end

  defp record(
         [:octoroom_agent, :turn, :latency],
         m,
         meta,
         now_ms,
         _wall_at,
         state
       ) do
    room_id = meta[:room_id]
    agent_id = meta[:agent_id]
    turn_id = meta[:turn_id]

    case lookup_utterance(state, room_id, agent_id, turn_id) do
      nil ->
        state

      utterance_id ->
        marker = %{kind: :first_audio, at_ms: now_ms, label: "first audio"}

        state =
          if turn_id,
            do: put_in(state.turn_utterance[{room_id, agent_id, turn_id}], utterance_id),
            else: state

        update_utterance(state, utterance_id, fn u ->
          lane =
            u.lanes
            |> Map.get(agent_id, new_lane(agent_id))
            |> Map.put(:latency, m)
            |> Map.put(:turn_id, turn_id)
            |> Map.update(:markers, [marker], &(&1 ++ [marker]))

          u |> put_in([:lanes, agent_id], lane) |> recompute_bounds()
        end)
    end
  end

  defp record(
         [:octoroom_agent, :live, :session],
         m,
         meta,
         now_ms,
         wall_at,
         state
       ) do
    dur = (m[:duration_ms] || 0) * 1.0
    {span_id, state} = next_id(state)
    event = meta[:event] || :event

    span = %{
      id: span_id,
      kind: :live_session,
      label: "live #{event} (#{meta[:agent_id] || meta[:provider]})",
      start_ms: now_ms - dur,
      end_ms: max(now_ms, now_ms - dur + 5.0),
      duration_ms: dur,
      status: if(event in [:error, :disconnected], do: :error, else: :ok),
      meta:
        compact_map(%{
          agent_id: meta[:agent_id],
          provider: meta[:provider],
          model: meta[:model],
          transport: meta[:transport],
          event: event,
          duration_ms: m[:duration_ms],
          reason: if(meta[:reason], do: inspect(meta[:reason]))
        })
    }

    append_join_spans(meta[:room_id], [span], now_ms, wall_at, state, false)
  end

  defp record(
         [:octoroom_agent, :live, :response, :stop],
         m,
         meta,
         now_ms,
         wall_at,
         state
       ) do
    room_id = meta[:room_id]
    agent_id = meta[:agent_id] || to_string(meta[:provider] || "live")
    ended_ms = (m[:ended_at_ms] || now_ms) * 1.0
    dur = (m[:duration_ms] || 0) * 1.0
    start_ms = ended_ms - dur
    latency_ms = m[:response_latency_ms]
    speech_ref_ms = if is_number(latency_ms), do: start_ms - latency_ms, else: start_ms

    {call_id, state} = ensure_call(room_id, speech_ref_ms, wall_at, state)

    {utterance_id, state} =
      find_or_create_live_utterance(
        call_id,
        room_id,
        meta[:speaker],
        meta[:user_text],
        speech_ref_ms,
        ended_ms,
        wall_at,
        meta[:typed] == true,
        state
      )

    {span_id, state} = next_id(state)
    status = meta[:status] || :ok

    live_span = %{
      id: span_id,
      kind: :live,
      label: "live (#{short_model(meta[:model] || "s2s")})",
      start_ms: start_ms,
      end_ms: max(ended_ms, start_ms + 5.0),
      duration_ms: dur,
      first_output_ms: nil,
      status: status,
      meta:
        compact_map(%{
          provider: meta[:provider],
          model: meta[:model],
          voice: meta[:voice],
          transport: meta[:transport],
          status: status,
          duration_ms: round(dur),
          audio_ms: m[:audio_ms],
          outputs: m[:outputs],
          response_latency_ms: latency_ms,
          user_text: meta[:user_text],
          assistant_text: meta[:assistant_text],
          reason: if(meta[:reason], do: inspect(meta[:reason]))
        })
    }

    {spans, state} =
      if is_number(latency_ms) and latency_ms > 0 do
        {wait_id, state} = next_id(state)

        think_span = %{
          id: wait_id,
          kind: :stt,
          label: "live think",
          start_ms: speech_ref_ms,
          end_ms: start_ms,
          duration_ms: latency_ms * 1.0,
          first_output_ms: nil,
          status: :ok,
          meta: %{response_latency_ms: latency_ms, transport: meta[:transport]}
        }

        {[think_span, live_span], state}
      else
        {[live_span], state}
      end

    marker = %{kind: :first_audio, at_ms: start_ms, label: "first audio"}

    latency =
      if is_number(latency_ms),
        do: %{processing_ms: latency_ms, wait_ms: 0, audio_ms: latency_ms},
        else: %{processing_ms: round(dur), wait_ms: 0, audio_ms: round(dur)}

    state =
      update_utterance(state, utterance_id, fn u ->
        lane =
          u.lanes
          |> Map.get(agent_id, new_lane(agent_id))
          |> Map.merge(%{
            outcome: :reply,
            why: if(meta[:typed], do: :typed, else: meta[:transport] || :live),
            latency: latency
          })
          |> append_spans(spans)
          |> Map.update(:markers, [marker], &(&1 ++ [marker]))

        u
        |> put_in([:lanes, agent_id], lane)
        |> maybe_fill_text(meta[:user_text])
        |> maybe_fill_speaker(meta[:speaker])
        |> recompute_bounds()
      end)

    broadcast_room_spans(room_id, agent_id, spans, now_ms)
    put_in(state.active_utterance[{room_id, agent_id}], utterance_id)
  end

  defp record(
         [:octoroom_agent, :pipeline, :interruption],
         m,
         meta,
         now_ms,
         _wall_at,
         state
       ) do
    room_id = meta[:room_id]
    agent_id = meta[:agent_id]

    case Map.get(state.active_utterance, {room_id, agent_id}) do
      nil ->
        state

      utterance_id ->
        marker = %{
          kind: :interruption,
          at_ms: now_ms,
          label: "interrupted (#{m[:killed_tasks] || 0} killed)"
        }

        update_utterance(state, utterance_id, fn u ->
          if now_ms - u.t_end_ms <= 15_000.0 do
            lane =
              u.lanes
              |> Map.get(agent_id, new_lane(agent_id))
              |> Map.update(:markers, [marker], &(&1 ++ [marker]))

            u |> put_in([:lanes, agent_id], lane) |> recompute_bounds()
          else
            u
          end
        end)
    end
  end

  # -- Room & WebRTC join events --

  defp record([:octoroom, :participant, :join], _m, meta, now_ms, wall_at, state) do
    {span_id, state} = next_id(state)

    span = %{
      id: span_id,
      kind: :join,
      label: "participant join (#{short_id(meta[:id])})",
      start_ms: now_ms,
      end_ms: now_ms + 5.0,
      duration_ms: 0.0,
      status: :ok,
      meta: %{participant_id: meta[:id]}
    }

    append_join_spans(meta[:room_id], [span], now_ms, wall_at, state, true)
  end

  defp record([:octoroom, :participant, :connected], m, meta, now_ms, wall_at, state) do
    {spans, state} = build_connected_spans(m, meta, now_ms, state)
    append_join_spans(meta[:room_id], spans, now_ms, wall_at, state, false)
  end

  defp record([:octoroom, :participant, :first_pull], m, meta, now_ms, wall_at, state) do
    dur = (m[:since_connected_ms] || 0) * 1.0
    {span_id, state} = next_id(state)

    span = %{
      id: span_id,
      kind: :pull,
      label: "first pull (#{m[:tracks] || 0} tracks)",
      start_ms: now_ms - dur,
      end_ms: now_ms,
      duration_ms: dur,
      status: :ok,
      meta: %{
        participant_id: meta[:id],
        tracks: m[:tracks],
        total_since_join_ms: m[:duration_ms]
      }
    }

    append_join_spans(meta[:room_id], [span], now_ms, wall_at, state, false)
  end

  defp record([:octoroom, :cloudflare, :request], m, meta, now_ms, wall_at, state) do
    dur = (m[:duration_ms] || 0) * 1.0
    {span_id, state} = next_id(state)
    method = meta[:method] |> to_string() |> String.upcase()
    path = short_cf_path(meta[:path])

    span = %{
      id: span_id,
      kind: :cloudflare,
      label: "CF #{method} #{path}",
      start_ms: now_ms - dur,
      end_ms: now_ms,
      duration_ms: dur,
      status: if(meta[:result] == :ok, do: :ok, else: :error),
      meta: %{method: method, path: meta[:path], result: meta[:result]}
    }

    append_join_spans(meta[:room_id], [span], now_ms, wall_at, state, false)
  end

  defp record([:octoroom, :peer, :connect], m, meta, now_ms, wall_at, state) do
    dur = (m[:duration_ms] || 0) * 1.0
    {span_id, state} = next_id(state)

    span = %{
      id: span_id,
      kind: :peer,
      label: "peer connect (#{meta[:worker_id]})",
      start_ms: now_ms - dur,
      end_ms: now_ms,
      duration_ms: dur,
      status: :ok,
      meta: %{worker_id: meta[:worker_id]}
    }

    append_join_spans(meta[:room_id], [span], now_ms, wall_at, state, false)
  end

  defp record([:octoroom, :outlet, :live], m, meta, now_ms, wall_at, state) do
    dur = (m[:duration_ms] || 0) * 1.0
    {span_id, state} = next_id(state)

    span = %{
      id: span_id,
      kind: :outlet,
      label: "outlet live (#{meta[:worker_id] || meta[:name]})",
      start_ms: now_ms - dur,
      end_ms: now_ms,
      duration_ms: dur,
      status: :ok,
      meta: %{worker_id: meta[:worker_id], name: meta[:name]}
    }

    append_join_spans(meta[:room_id], [span], now_ms, wall_at, state, false)
  end

  defp record([:octoroom, :pull, :stop], m, meta, now_ms, wall_at, state) do
    dur = (m[:duration_ms] || 0) * 1.0
    {span_id, state} = next_id(state)

    span = %{
      id: span_id,
      kind: :pull,
      label: "pull (#{m[:tracks] || 0} tracks)",
      start_ms: now_ms - dur,
      end_ms: now_ms,
      duration_ms: dur,
      status: :ok,
      meta: %{participant_id: meta[:participant_id], tracks: m[:tracks]}
    }

    append_join_spans(meta[:room_id], [span], now_ms, wall_at, state, false)
  end

  defp record([:octoroom, :failure], m, meta, now_ms, wall_at, state) do
    {span_id, state} = next_id(state)

    span = %{
      id: span_id,
      kind: :failure,
      label: "failure: #{meta[:name]}",
      start_ms: now_ms - 5.0,
      end_ms: now_ms,
      duration_ms: 0.0,
      status: :error,
      meta: %{
        id: meta[:id],
        name: meta[:name],
        count: m[:count],
        given_up: meta[:given_up],
        reason: inspect(meta[:reason])
      }
    }

    append_join_spans(meta[:room_id], [span], now_ms, wall_at, state, false)
  end

  defp record(_event, _m, _meta, _now_ms, _wall_at, state), do: state

  # -- Helpers --

  defp build_async_span(event_status, m, meta, now_ms, state) do
    dur = native_to_ms(m[:duration] || 0)
    first_out = if m[:first_output_duration], do: native_to_ms(m.first_output_duration)
    {span_id, state} = next_id(state)
    kind = span_kind(meta[:processor])

    status =
      case event_status do
        :exception -> :error
        :stop -> meta[:status] || :ok
      end

    label =
      case {kind, meta[:model], meta[:provider]} do
        {:llm, model, _} when is_binary(model) -> "llm (#{short_model(model)})"
        {:tts, model, _} when is_binary(model) -> "tts (#{short_model(model)})"
        {:decisions, model, _} when is_binary(model) -> "decisions (#{short_model(model)})"
        {:tools, _, _} -> "tools"
        {:transcriber, model, _} when is_binary(model) -> "transcriber (#{short_model(model)})"
        {:transcriber, _, _} -> "transcriber"
        _ -> "#{meta[:processor]}:#{meta[:task]}"
      end

    details =
      compact_map(%{
        processor: meta[:processor],
        task: meta[:task],
        status: status,
        provider: meta[:provider],
        model: meta[:model],
        voice: meta[:voice],
        modality: meta[:modality],
        chars: meta[:chars],
        audio_ms: meta[:audio_ms],
        outputs: m[:outputs],
        first_output_ms: first_out && Float.round(first_out, 1),
        duration_ms: Float.round(dur, 1),
        sync_tools: meta[:sync_tools],
        reason: if(meta[:reason], do: inspect(meta[:reason]))
      })

    span = %{
      id: span_id,
      kind: kind,
      label: label,
      start_ms: now_ms - dur,
      end_ms: now_ms,
      duration_ms: dur,
      first_output_ms: first_out,
      status: status,
      meta: details
    }

    {span, state}
  end

  defp build_front_spans(speech_end_ms, decided_ms, speech_to_decided, decision_span, meta, state) do
    cond do
      decision_span != nil ->
        stt_end = min(max(decision_span.start_ms, speech_end_ms), decided_ms)
        stt_dur = max(stt_end - speech_end_ms, 0.0)

        if stt_dur > 0.5 do
          {stt_id, state} = next_id(state)

          stt_span = %{
            id: stt_id,
            kind: :stt,
            label: stt_label(meta),
            start_ms: speech_end_ms,
            end_ms: stt_end,
            duration_ms: stt_dur,
            first_output_ms: nil,
            status: :ok,
            meta:
              compact_map(%{
                provider: meta[:stt_provider],
                model: meta[:stt_model],
                derived: "speech_end to decisions start",
                duration_ms: Float.round(stt_dur, 1),
                text: meta[:text]
              })
          }

          {[stt_span, decision_span], state}
        else
          {[decision_span], state}
        end

      speech_to_decided > 0.5 ->
        {stt_id, state} = next_id(state)

        stt_span = %{
          id: stt_id,
          kind: :stt,
          label: stt_label(meta),
          start_ms: speech_end_ms,
          end_ms: decided_ms,
          duration_ms: speech_to_decided,
          first_output_ms: nil,
          status: :ok,
          meta:
            compact_map(%{
              provider: meta[:stt_provider],
              model: meta[:stt_model],
              duration_ms: Float.round(speech_to_decided, 1),
              text: meta[:text]
            })
        }

        {[stt_span], state}

      true ->
        {[], state}
    end
  end

  defp stt_label(meta) do
    model =
      case meta[:stt_model] do
        m when is_binary(m) and m != "" -> short_model(m)
        _ -> nil
      end

    case {meta[:stt_provider], model} do
      {p, m} when not is_nil(p) and is_binary(m) -> "stt (#{p}/#{m})"
      {nil, m} when is_binary(m) -> "stt (#{m})"
      {p, nil} when not is_nil(p) -> "stt (#{p})"
      _ -> "stt"
    end
  end

  defp attach_backend_span(room_id, agent_id, turn_id, span, wall_at, state) do
    {utterance_id, state} =
      case lookup_utterance(state, room_id, agent_id, turn_id) do
        nil ->
          {call_id, state} = ensure_call(room_id, span.start_ms, wall_at, state)
          {id, state} = next_seq(state)

          utterance = %{
            id: id,
            call_id: call_id,
            room_id: room_id || "unknown",
            input: nil,
            speaker: nil,
            text: nil,
            wall_at: wall_at,
            t0_ms: span.start_ms,
            t_end_ms: span.end_ms,
            lanes: %{}
          }

          utterances = Enum.take([utterance | state.utterances], @max_utterances)
          state = %{state | utterances: utterances}
          state = put_in(state.active_utterance[{room_id, agent_id}], id)
          {id, state}

        id ->
          {id, state}
      end

    state =
      if turn_id,
        do: put_in(state.turn_utterance[{room_id, agent_id, turn_id}], utterance_id),
        else: state

    update_utterance(state, utterance_id, fn u ->
      lane =
        u.lanes
        |> Map.get(agent_id, new_lane(agent_id))
        |> then(fn l -> if turn_id, do: Map.put(l, :turn_id, turn_id), else: l end)
        |> append_spans([span])

      u |> put_in([:lanes, agent_id], lane) |> recompute_bounds()
    end)
  end

  defp lookup_utterance(state, room_id, agent_id, turn_id) do
    (turn_id && Map.get(state.turn_utterance, {room_id, agent_id, turn_id})) ||
      Map.get(state.active_utterance, {room_id, agent_id})
  end

  defp find_or_create_utterance(
         call_id,
         room_id,
         input,
         speaker,
         text,
         speech_end_ms,
         now_ms,
         wall_at,
         typed?,
         state
       ) do
    match =
      if typed? do
        nil
      else
        Enum.find(state.utterances, fn u ->
          u.call_id == call_id and u.input == input and
            abs(u.t0_ms - speech_end_ms) <= @utterance_group_window_ms
        end)
      end

    case match do
      %{id: id} ->
        {id, state}

      nil ->
        {id, state} = next_seq(state)

        utterance = %{
          id: id,
          call_id: call_id,
          room_id: room_id || "unknown",
          input: input,
          speaker: speaker,
          text: text,
          wall_at: wall_at,
          t0_ms: speech_end_ms,
          t_end_ms: now_ms,
          lanes: %{}
        }

        utterances = Enum.take([utterance | state.utterances], @max_utterances)
        {id, %{state | utterances: utterances}}
    end
  end

  defp find_or_create_live_utterance(
         call_id,
         room_id,
         speaker,
         text,
         t0_ms,
         t_end_ms,
         wall_at,
         typed?,
         state
       ) do
    match =
      if typed? do
        nil
      else
        Enum.find(state.utterances, fn u ->
          u.call_id == call_id and abs(u.t0_ms - t0_ms) <= 3_000.0
        end)
      end

    case match do
      %{id: id} ->
        {id, state}

      nil ->
        {id, state} = next_seq(state)

        utterance = %{
          id: id,
          call_id: call_id,
          room_id: room_id || "unknown",
          input: nil,
          speaker: speaker,
          text: text,
          wall_at: wall_at,
          t0_ms: t0_ms,
          t_end_ms: t_end_ms,
          lanes: %{}
        }

        utterances = Enum.take([utterance | state.utterances], @max_utterances)
        {id, %{state | utterances: utterances}}
    end
  end

  defp update_utterance(state, id, fun) do
    utterances =
      Enum.map(state.utterances, fn
        %{id: ^id} = u -> fun.(u)
        u -> u
      end)

    %{state | utterances: utterances}
  end

  defp pop_recent_decision(pending, key, now_ms) do
    case Map.get(pending, key, []) do
      [latest | rest] when now_ms - latest.end_ms <= 2_000.0 ->
        {latest, Map.put(pending, key, rest)}

      _ ->
        {nil, pending}
    end
  end

  defp new_lane(agent_id) do
    %{
      agent_id: agent_id || "agent",
      turn_id: nil,
      outcome: nil,
      why: nil,
      decision: nil,
      latency: nil,
      spans: [],
      markers: []
    }
  end

  defp append_spans(lane, spans) do
    sorted = Enum.sort_by(lane.spans ++ spans, & &1.start_ms)
    %{lane | spans: sorted}
  end

  defp recompute_bounds(u) do
    times =
      for {_id, lane} <- u.lanes,
          item <-
            Enum.flat_map(lane.spans, &[&1.start_ms, &1.end_ms]) ++
              Enum.map(lane.markers, & &1.at_ms),
          do: item

    case times do
      [] ->
        u

      list ->
        %{u | t0_ms: min(u.t0_ms, Enum.min(list)), t_end_ms: max(u.t_end_ms, Enum.max(list))}
    end
  end

  defp maybe_fill_text(%{text: nil} = u, text) when is_binary(text) and text != "",
    do: %{u | text: text}

  defp maybe_fill_text(u, _), do: u

  defp maybe_fill_speaker(%{speaker: nil} = u, speaker) when is_binary(speaker),
    do: %{u | speaker: speaker}

  defp maybe_fill_speaker(u, _), do: u

  # -- Join grouping --

  defp build_connected_spans(m, meta, now_ms, state) do
    total = (m[:duration_ms] || 0) * 1.0
    t0 = now_ms - total

    steps =
      if Map.has_key?(m, :client_ice_ms) do
        [
          {:client, "client join", m[:client_join_ms]},
          {:client, "client media (mic/cam)", m[:client_media_ms]},
          {:client, if(meta[:ice_timed_out], do: "client ICE (timed out)", else: "client ICE"),
           m[:client_ice_ms]},
          {:client, "client publish", m[:client_publish_ms]},
          {:client, "client connect (DTLS)", m[:client_connect_ms]}
        ]
      else
        [
          {:join, "before publish", m[:before_publish_ms]},
          {:join, "publish", m[:publish_ms]},
          {:join, "connect", m[:connect_ms]}
        ]
      end
      |> Enum.filter(fn {_, _, v} -> is_number(v) and v > 0 end)

    sum_steps = Enum.reduce(steps, 0.0, fn {_, _, v}, acc -> acc + v end)
    start_cursor = max(t0, now_ms - sum_steps)

    {spans, _cursor, state} =
      Enum.reduce(steps, {[], start_cursor, state}, fn {kind, label, v}, {acc, cursor, state} ->
        dur = v * 1.0
        {span_id, state} = next_id(state)

        span = %{
          id: span_id,
          kind: kind,
          label: label,
          start_ms: cursor,
          end_ms: cursor + dur,
          duration_ms: dur,
          status: :ok,
          meta: %{
            participant_id: meta[:id],
            sources: meta[:sources],
            total_ms: m[:duration_ms]
          }
        }

        {[span | acc], cursor + dur, state}
      end)

    {Enum.reverse(spans), state}
  end

  defp append_join_spans(room_id, spans, now_ms, wall_at, state, force_new?) do
    room_id = room_id || "unknown"
    {call_id, state} = ensure_call(room_id, now_ms, wall_at, state)

    match_index =
      if force_new? do
        nil
      else
        Enum.find_index(state.joins, fn j ->
          j.call_id == call_id and abs(now_ms - j.t_end_ms) <= @join_group_window_ms
        end)
      end

    case match_index do
      nil ->
        {id, state} = next_seq(state)
        t0 = spans |> Enum.map(& &1.start_ms) |> Enum.min(fn -> now_ms end)
        t_end = spans |> Enum.map(& &1.end_ms) |> Enum.max(fn -> now_ms end)

        join = %{
          id: id,
          call_id: call_id,
          room_id: room_id,
          wall_at: wall_at,
          t0_ms: t0,
          t_end_ms: t_end,
          spans: Enum.sort_by(spans, & &1.start_ms)
        }

        %{state | joins: Enum.take([join | state.joins], @max_joins)}

      idx ->
        joins =
          List.update_at(state.joins, idx, fn j ->
            all = Enum.sort_by(j.spans ++ spans, & &1.start_ms)
            t0 = all |> Enum.map(& &1.start_ms) |> Enum.min(fn -> j.t0_ms end)
            t_end = all |> Enum.map(& &1.end_ms) |> Enum.max(fn -> j.t_end_ms end)
            %{j | spans: all, t0_ms: t0, t_end_ms: t_end}
          end)

        %{state | joins: joins}
    end
  end

  # -- Calls --

  defp ensure_call(room_id, now_ms, wall_at, state) do
    room_id = room_id || "unknown"

    case Map.get(state.active_call, room_id) do
      nil -> start_call(room_id, nil, now_ms, wall_at, state)
      call_id -> {call_id, state}
    end
  end

  defp start_call(room_id, run, now_ms, wall_at, state) do
    {call_id, state} = next_seq(state)

    call = %{
      id: call_id,
      room_id: room_id,
      run: run,
      status: :live,
      started_at: wall_at,
      ended_at: nil,
      started_ms: now_ms,
      ended_ms: nil
    }

    calls = Enum.take([call | state.calls], @max_calls)
    active = Map.put(state.active_call, room_id, call_id)
    {call_id, %{state | calls: calls, active_call: active}}
  end

  defp end_active_call(room_id, now_ms, wall_at, state) do
    case Map.pop(state.active_call, room_id) do
      {nil, _} ->
        state

      {call_id, active} ->
        calls =
          Enum.map(state.calls, fn
            %{id: ^call_id} = c ->
              %{c | status: :ended, ended_at: wall_at, ended_ms: now_ms}

            c ->
              c
          end)

        # Clear active utterance pointers for this room so the next call starts fresh.
        active_u =
          Map.reject(state.active_utterance, fn {{r, _agent}, _id} -> r == room_id end)

        turn_u =
          Map.reject(state.turn_utterance, fn {{r, _agent, _tid}, _id} -> r == room_id end)

        %{
          state
          | calls: calls,
            active_call: active,
            active_utterance: active_u,
            turn_utterance: turn_u
        }
    end
  end

  defp span_kind(:llm), do: :llm
  defp span_kind(:tts), do: :tts
  defp span_kind(:decisions), do: :decisions
  defp span_kind(:tools), do: :tools
  defp span_kind(:transcriber), do: :transcriber
  defp span_kind(_), do: :other

  defp short_model(model) when is_binary(model) do
    model |> String.split("/") |> List.last() |> String.split(":") |> List.last()
  end

  defp short_cf_path("/sessions/new"), do: "/sessions/new"

  defp short_cf_path(path) when is_binary(path) do
    path
    |> String.replace(~r|/sessions/[^/]+|, "/sessions/:id")
  end

  defp short_cf_path(other), do: to_string(other)

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(other), do: to_string(other)

  defp next_seq(state) do
    seq = state.seq + 1
    {seq, %{state | seq: seq}}
  end

  defp next_id(state) do
    {seq, state} = next_seq(state)
    {"s-#{seq}", state}
  end

  defp native_to_ms(native), do: System.convert_time_unit(native, :native, :microsecond) / 1_000.0

  defp compact_map(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) or v == [] end)
  end
end
