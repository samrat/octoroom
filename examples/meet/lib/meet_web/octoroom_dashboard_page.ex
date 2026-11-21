defmodule MeetWeb.OctoroomDashboardPage do
  @moduledoc """
  Native Phoenix LiveDashboard page rendering live horizontal waterfalls for
  voice agent turns and room joins.

  Mounted via `additional_pages: [octoroom: MeetWeb.OctoroomDashboardPage]` at
  `/dev/dashboard/octoroom`.
  """
  use Phoenix.LiveDashboard.PageBuilder, refresher?: false

  alias MeetWeb.TraceStore

  @impl true
  def menu_link(_session, _capabilities) do
    {:ok, "Octoroom"}
  end

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Meet.PubSub, TraceStore.topic())
    end

    tab = if params["tab"] == "joins", do: :joins, else: :turns
    {:ok, socket |> assign(tab: tab, selected: nil, selected_call: :latest) |> load_snapshot()}
  end

  @impl true
  def handle_info(:traces_updated, socket) do
    {:noreply, load_snapshot(socket)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab = if tab == "joins", do: :joins, else: :turns
    {:noreply, assign(socket, tab: tab, selected: nil)}
  end

  def handle_event("select_call", %{"call" => "all"}, socket) do
    {:noreply, assign(socket, selected_call: :all, selected: nil)}
  end

  def handle_event("select_call", %{"call" => "latest"}, socket) do
    {:noreply, assign(socket, selected_call: :latest, selected: nil)}
  end

  def handle_event("select_call", %{"call" => id}, socket) do
    case Integer.parse(id) do
      {call_id, ""} -> {:noreply, assign(socket, selected_call: call_id, selected: nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("select_span", %{"card" => card, "span" => span_id}, socket) do
    key = {card, span_id}
    selected = if socket.assigns.selected == key, do: nil, else: key
    {:noreply, assign(socket, selected: selected)}
  end

  def handle_event("clear", _params, socket) do
    TraceStore.clear()
    {:noreply, assign(socket, selected: nil, selected_call: :latest) |> load_snapshot()}
  end

  defp load_snapshot(socket) do
    %{calls: calls, utterances: utterances, joins: joins} = TraceStore.snapshot()
    assign(socket, calls: calls, utterances: utterances, joins: joins)
  end

  @impl true
  def render(assigns) do
    active_call_id = resolve_call_id(assigns.selected_call, assigns.calls)
    utterances = filter_by_call(assigns.utterances, active_call_id)
    joins = filter_by_call(assigns.joins, active_call_id)
    turn_counts = Enum.frequencies_by(assigns.utterances, & &1.call_id)
    join_counts = Enum.frequencies_by(assigns.joins, & &1.call_id)
    stats = compute_stats(utterances)

    assigns =
      assign(assigns,
        active_call_id: active_call_id,
        visible_utterances: utterances,
        visible_joins: joins,
        turn_counts: turn_counts,
        join_counts: join_counts,
        stats: stats
      )

    ~H"""
    <div class="octo-wf">
      <style>
        .octo-wf { font-size: 13px; color: #1f2937; }
        .octo-wf .wf-toolbar { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 16px; }
        .octo-wf .wf-tabs { display: inline-flex; background: #f3f4f6; border-radius: 8px; padding: 3px; gap: 2px; }
        .octo-wf .wf-tab { border: 0; background: transparent; padding: 6px 14px; border-radius: 6px; font-weight: 600; font-size: 13px; color: #4b5563; cursor: pointer; }
        .octo-wf .wf-tab.active { background: #fff; color: #111827; box-shadow: 0 1px 2px rgba(0,0,0,.08); }
        .octo-wf .wf-controls { display: flex; align-items: center; gap: 8px; }
        .octo-wf .wf-select { border: 1px solid #d1d5db; border-radius: 6px; padding: 5px 10px; font-size: 12px; background: #fff; }
        .octo-wf .wf-btn { border: 1px solid #d1d5db; background: #fff; border-radius: 6px; padding: 5px 12px; font-size: 12px; font-weight: 500; color: #374151; cursor: pointer; }
        .octo-wf .wf-btn:hover { background: #f9fafb; }

        .octo-wf .wf-kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(145px, 1fr)); gap: 10px; margin-bottom: 14px; }
        .octo-wf .wf-kpi { background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 10px 14px; }
        .octo-wf .wf-kpi-label { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: #6b7280; font-weight: 600; }
        .octo-wf .wf-kpi-val { font-size: 20px; font-weight: 700; font-variant-numeric: tabular-nums; color: #111827; margin-top: 2px; }
        .octo-wf .wf-kpi-sub { font-size: 11px; color: #9ca3af; }

        .octo-wf .wf-legend { display: flex; flex-wrap: wrap; gap: 14px; align-items: center; font-size: 12px; color: #4b5563; margin-bottom: 14px; padding: 8px 12px; background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; }
        .octo-wf .wf-swatch { display: inline-flex; align-items: center; gap: 6px; }
        .octo-wf .wf-box { width: 12px; height: 10px; border-radius: 2px; display: inline-block; }

        .octo-wf .wf-card { background: #fff; border: 1px solid #e5e7eb; border-radius: 10px; margin-bottom: 14px; overflow: hidden; box-shadow: 0 1px 2px rgba(0,0,0,.03); }
        .octo-wf .wf-card-head { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 8px; padding: 10px 14px; background: #f9fafb; border-bottom: 1px solid #e5e7eb; }
        .octo-wf .wf-title { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }
        .octo-wf .wf-time { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; color: #6b7280; }
        .octo-wf .wf-room { font-size: 11px; background: #eef2ff; color: #3730a3; padding: 2px 7px; border-radius: 999px; font-weight: 600; }
        .octo-wf .wf-speaker { font-weight: 700; color: #111827; }
        .octo-wf .wf-quote { color: #374151; font-style: italic; max-width: 520px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .octo-wf .wf-totals { display: flex; align-items: center; gap: 6px; font-variant-numeric: tabular-nums; }
        .octo-wf .wf-pill { font-size: 11px; font-weight: 600; padding: 2px 8px; border-radius: 999px; background: #ecfdf5; color: #065f46; }
        .octo-wf .wf-pill.wait { background: #f3f4f6; color: #4b5563; }
        .octo-wf .wf-pill.muted { background: #f3f4f6; color: #6b7280; }

        .octo-wf .wf-ruler { display: grid; grid-template-columns: 200px 1fr; border-bottom: 1px solid #f3f4f6; background: #fcfcfd; }
        .octo-wf .wf-ruler-left { padding: 4px 12px; font-size: 10px; text-transform: uppercase; letter-spacing: .05em; color: #9ca3af; font-weight: 600; }
        .octo-wf .wf-ruler-track { position: relative; height: 22px; margin-right: 16px; }
        .octo-wf .wf-tick { position: absolute; top: 3px; font-size: 10px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #9ca3af; transform: translateX(-50%); white-space: nowrap; }
        .octo-wf .wf-tick.first { transform: none; }
        .octo-wf .wf-tick.last { transform: translateX(-100%); }

        .octo-wf .wf-lane { display: grid; grid-template-columns: 200px 1fr; border-bottom: 1px solid #f3f4f6; }
        .octo-wf .wf-lane:last-child { border-bottom: 0; }
        .octo-wf .wf-lane-meta { padding: 10px 12px; border-right: 1px solid #f3f4f6; background: #fcfcfd; }
        .octo-wf .wf-agent { font-weight: 700; color: #111827; font-size: 13px; display: flex; align-items: center; gap: 6px; }
        .octo-wf .wf-badge { font-size: 10px; font-weight: 700; text-transform: uppercase; padding: 1px 6px; border-radius: 4px; }
        .octo-wf .wf-badge.reply { background: #dbeafe; color: #1e40af; }
        .octo-wf .wf-badge.wait { background: #fef3c7; color: #92400e; }
        .octo-wf .wf-badge.listen { background: #f3f4f6; color: #6b7280; }
        .octo-wf .wf-why { font-size: 11px; color: #6b7280; margin-top: 2px; }

        .octo-wf .wf-lane-bars { padding: 6px 16px 6px 0; position: relative; }
        .octo-wf .wf-row { position: relative; height: 24px; display: flex; align-items: center; }
        .octo-wf .wf-gridline { position: absolute; top: 0; bottom: 0; width: 1px; background: #f3f4f6; pointer-events: none; }

        .octo-wf .wf-bar-btn { position: absolute; height: 18px; min-width: 3px; border: 0; border-radius: 4px; padding: 0; cursor: pointer; overflow: visible; transition: filter .1s; }
        .octo-wf .wf-bar-btn:hover { filter: brightness(0.92); }
        .octo-wf .wf-bar-btn.selected { outline: 2px solid #111827; outline-offset: 1px; z-index: 4; }
        .octo-wf .wf-bar-tail { position: absolute; top: 0; bottom: 0; right: 0; background: rgba(255,255,255,0.42); border-radius: 0 4px 4px 0; pointer-events: none; }
        .octo-wf .wf-bar-pin { position: absolute; top: -2px; bottom: -2px; width: 2px; background: #111827; pointer-events: none; z-index: 2; }
        .octo-wf .wf-bar-label { position: absolute; top: 1px; left: calc(100% + 6px); font-size: 11px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; color: #374151; white-space: nowrap; pointer-events: none; }
        .octo-wf .wf-bar-label.left-side { left: auto; right: calc(100% + 6px); }

        .octo-wf .wf-marker { position: absolute; top: 0; bottom: 0; width: 2px; pointer-events: none; z-index: 3; }
        .octo-wf .wf-marker.first_audio { background: #10b981; }
        .octo-wf .wf-marker.interruption { background: #ef4444; }
        .octo-wf .wf-marker-tag { position: absolute; top: -1px; left: 4px; font-size: 9px; font-weight: 700; text-transform: uppercase; white-space: nowrap; }
        .octo-wf .wf-marker-tag.left-side { left: auto; right: 4px; }
        .octo-wf .wf-marker.first_audio .wf-marker-tag { color: #059669; }
        .octo-wf .wf-marker.interruption .wf-marker-tag { color: #dc2626; }

        /* Stage colors */
        .octo-wf .kind-stt { background: #64748b; }
        .octo-wf .kind-decisions { background: #f59e0b; }
        .octo-wf .kind-floor_wait { background: repeating-linear-gradient(45deg, #d1d5db, #d1d5db 5px, #e5e7eb 5px, #e5e7eb 10px); border: 1px solid #9ca3af; }
        .octo-wf .kind-llm { background: #4f46e5; }
        .octo-wf .kind-tools, .octo-wf .kind-tool { background: #9333ea; }
        .octo-wf .kind-tts { background: #10b981; }
        .octo-wf .kind-live { background: #0284c7; }
        .octo-wf .kind-live_session { background: #14b8a6; }
        .octo-wf .kind-transcriber { background: #0ea5e9; }
        .octo-wf .kind-client { background: #3b82f6; }
        .octo-wf .kind-join { background: #6366f1; }
        .octo-wf .kind-cloudflare { background: #f97316; }
        .octo-wf .kind-peer { background: #0d9488; }
        .octo-wf .kind-outlet { background: #10b981; }
        .octo-wf .kind-pull { background: #0284c7; }
        .octo-wf .kind-failure, .octo-wf .status-error { background: #ef4444; }
        .octo-wf .status-interrupted, .octo-wf .status-cancelled { background: #fb923c; }

        .octo-wf .wf-detail { padding: 10px 14px; background: #111827; color: #f9fafb; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; border-top: 1px solid #374151; }
        .octo-wf .wf-detail-grid { display: flex; flex-wrap: wrap; gap: 14px; margin-top: 4px; }
        .octo-wf .wf-detail-k { color: #9ca3af; }
        .octo-wf .wf-empty { background: #fff; border: 1px dashed #d1d5db; border-radius: 10px; padding: 36px; text-align: center; color: #6b7280; }

        .octo-wf .wf-calls { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 14px; }
        .octo-wf .wf-call { display: inline-flex; align-items: center; gap: 8px; border: 1px solid #e5e7eb; background: #fff; border-radius: 8px; padding: 6px 11px; cursor: pointer; text-align: left; font-size: 12px; color: #374151; }
        .octo-wf .wf-call:hover { border-color: #cbd5e1; background: #f9fafb; }
        .octo-wf .wf-call.active { border-color: #4f46e5; background: #eef2ff; color: #1e1b4b; box-shadow: 0 0 0 1px #4f46e5; }
        .octo-wf .wf-dot { width: 8px; height: 8px; border-radius: 999px; background: #9ca3af; flex-shrink: 0; }
        .octo-wf .wf-dot.live { background: #10b981; box-shadow: 0 0 0 3px rgba(16, 185, 129, 0.2); }
        .octo-wf .wf-call-name { font-weight: 700; }
        .octo-wf .wf-call-meta { font-size: 11px; color: #6b7280; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      </style>

      <div :if={@calls != []} class="wf-calls">
        <button
          :for={{call, idx} <- Enum.with_index(@calls)}
          type="button"
          class={"wf-call #{if @active_call_id == call.id, do: "active"}"}
          phx-click="select_call"
          phx-value-call={if idx == 0, do: "latest", else: call.id}
        >
          <span class={"wf-dot #{if call.status == :live, do: "live"}"}></span>
          <span class="wf-call-name">{call.room_id}</span>
          <span class="wf-call-meta">
            {fmt_time(call.started_at)} · {fmt_call_duration(call)} · {Map.get(
              @turn_counts,
              call.id,
              0
            )}t / {Map.get(@join_counts, call.id, 0)}j
          </span>
        </button>

        <button
          :if={length(@calls) > 1}
          type="button"
          class={"wf-call #{if @active_call_id == :all, do: "active"}"}
          phx-click="select_call"
          phx-value-call="all"
        >
          <span class="wf-call-name">All calls ({length(@calls)})</span>
        </button>
      </div>

      <div class="wf-toolbar">
        <div class="wf-tabs">
          <button
            type="button"
            class={"wf-tab #{if @tab == :turns, do: "active"}"}
            phx-click="switch_tab"
            phx-value-tab="turns"
          >
            Voice Turns ({length(@visible_utterances)})
          </button>
          <button
            type="button"
            class={"wf-tab #{if @tab == :joins, do: "active"}"}
            phx-click="switch_tab"
            phx-value-tab="joins"
          >
            Room Joins ({length(@visible_joins)})
          </button>
        </div>

        <div class="wf-controls">
          <button type="button" class="wf-btn" phx-click="clear">Clear</button>
        </div>
      </div>

      <%= if @tab == :turns do %>
        <div class="wf-kpis">
          <div class="wf-kpi">
            <div class="wf-kpi-label">Median Turn (ex-wait)</div>
            <div class="wf-kpi-val">{fmt_ms(@stats.processing_ms)}</div>
            <div class="wf-kpi-sub">speech end → first audio</div>
          </div>
          <div class="wf-kpi">
            <div class="wf-kpi-label">Median STT</div>
            <div class="wf-kpi-val">{fmt_ms(@stats.stt_ms)}</div>
            <div class="wf-kpi-sub">speech end → final transcript</div>
          </div>
          <div class="wf-kpi">
            <div class="wf-kpi-label">Median Decisions</div>
            <div class="wf-kpi-val">{fmt_ms(@stats.decisions_ms)}</div>
            <div class="wf-kpi-sub">gate model evaluation</div>
          </div>
          <div class="wf-kpi">
            <div class="wf-kpi-label">Median LLM TTFT</div>
            <div class="wf-kpi-val">{fmt_ms(@stats.llm_ttft_ms)}</div>
            <div class="wf-kpi-sub">first spoken token</div>
          </div>
          <div class="wf-kpi">
            <div class="wf-kpi-label">Median TTS TTFB</div>
            <div class="wf-kpi-val">{fmt_ms(@stats.tts_ttfb_ms)}</div>
            <div class="wf-kpi-sub">first audio chunk</div>
          </div>
        </div>

        <div class="wf-legend">
          <span class="wf-swatch"><span class="wf-box kind-stt"></span>STT</span>
          <span class="wf-swatch"><span class="wf-box kind-decisions"></span>Decisions</span>
          <span class="wf-swatch">
            <span class="wf-box kind-floor_wait"></span>Floor wait (intentional)
          </span>
          <span class="wf-swatch">
            <span class="wf-box kind-llm"></span>LLM (│ = TTFT, light = stream tail)
          </span>
          <span class="wf-swatch"><span class="wf-box kind-tool"></span>Tool</span>
          <span class="wf-swatch"><span class="wf-box kind-tts"></span>TTS (│ = TTFB)</span>
          <span class="wf-swatch"><span class="wf-box kind-live"></span>Live S2S</span>
          <span class="wf-swatch"><span class="wf-box status-error"></span>Error / Interrupted</span>
          <span style="margin-left: auto; color: #9ca3af;">Click any bar for details</span>
        </div>

        <div :if={@visible_utterances == []} class="wf-empty">
          No voice turns recorded yet. Join a room and talk or type to an assistant — waterfalls appear here live.
        </div>

        <div :for={u <- @visible_utterances} class="wf-card">
          <% total_span = max(u.t_end_ms - u.t0_ms, 10.0) %>
          <% reply_lane = reply_lane(u) %>
          <div class="wf-card-head">
            <div class="wf-title">
              <span class="wf-time">{fmt_time(u.wall_at)}</span>
              <span class="wf-room">{u.room_id}</span>
              <span :if={u.speaker} class="wf-speaker">{u.speaker}:</span>
              <span :if={u.text} class="wf-quote" title={u.text}>“{u.text}”</span>
              <span :if={!u.text} class="wf-quote">(audio / app-triggered turn)</span>
            </div>
            <div class="wf-totals">
              <%= if reply_lane && reply_lane.latency do %>
                <% proc_ms = reply_lane.latency[:processing_ms] || reply_lane.latency[:audio_ms] || 0 %>
                <% wait_ms = reply_lane.latency[:wait_ms] || 0 %>
                <span class="wf-pill">
                  {reply_lane.agent_id} · {round(proc_ms)} ms
                </span>
                <span :if={wait_ms > 0} class="wf-pill wait">
                  + {round(wait_ms)} ms floor wait
                </span>
              <% else %>
                <span class="wf-pill muted">no reply · {round(total_span)} ms</span>
              <% end %>
            </div>
          </div>

          <div class="wf-ruler">
            <div class="wf-ruler-left">Assistant</div>
            <div class="wf-ruler-track">
              <span class="wf-tick first" style="left: 0%;">0 ms</span>
              <span class="wf-tick" style="left: 25%;">{round(total_span * 0.25)} ms</span>
              <span class="wf-tick" style="left: 50%;">{round(total_span * 0.50)} ms</span>
              <span class="wf-tick" style="left: 75%;">{round(total_span * 0.75)} ms</span>
              <span class="wf-tick last" style="left: 100%;">{round(total_span)} ms</span>
            </div>
          </div>

          <div :for={{_id, lane} <- sorted_lanes(u.lanes)} class="wf-lane">
            <div class="wf-lane-meta">
              <div class="wf-agent">
                <span>{lane.agent_id}</span>
                <span :if={lane.outcome} class={"wf-badge #{lane.outcome}"}>{lane.outcome}</span>
              </div>
              <div :if={lane.why} class="wf-why">{lane.why}</div>
            </div>

            <div class="wf-lane-bars">
              <div class="wf-gridline" style="left: 25%;"></div>
              <div class="wf-gridline" style="left: 50%;"></div>
              <div class="wf-gridline" style="left: 75%;"></div>

              <div
                :for={marker <- lane.markers}
                class={"wf-marker #{marker.kind}"}
                style={"left: #{pct(marker.at_ms - u.t0_ms, total_span)}%;"}
              >
                <span class={"wf-marker-tag #{if pct(marker.at_ms - u.t0_ms, total_span) > 75, do: "left-side"}"}>
                  {marker.label}
                </span>
              </div>

              <div :for={span <- lane.spans} class="wf-row">
                <% left = pct(span.start_ms - u.t0_ms, total_span) %>
                <% width = max(pct(span.duration_ms, total_span), 0.5) %>
                <% selected? = @selected == {"u-#{u.id}", span.id} %>
                <button
                  type="button"
                  phx-click="select_span"
                  phx-value-card={"u-#{u.id}"}
                  phx-value-span={span.id}
                  class={"wf-bar-btn kind-#{span.kind} status-#{span.status} #{if selected?, do: "selected"}"}
                  style={"left: #{left}%; width: #{width}%;"}
                  title={"#{span.label} — #{fmt_ms(span.duration_ms)}"}
                >
                  <%= if span.first_output_ms && span.duration_ms > 0 do %>
                    <% pin_pct = min(max(span.first_output_ms / span.duration_ms * 100.0, 0.0), 100.0) %>
                    <span class="wf-bar-tail" style={"width: #{Float.round(100.0 - pin_pct, 2)}%;"}>
                    </span>
                    <span class="wf-bar-pin" style={"left: #{Float.round(pin_pct, 2)}%;"}></span>
                  <% end %>
                  <span class={"wf-bar-label #{if left + width > 72, do: "left-side"}"}>
                    {span_caption(span)}
                  </span>
                </button>
              </div>
            </div>
          </div>

          <%= if selected_span = find_selected_span(u, @selected) do %>
            <div class="wf-detail">
              <div><strong>{selected_span.label}</strong> ({fmt_ms(selected_span.duration_ms)})</div>
              <div class="wf-detail-grid">
                <span :for={{k, v} <- Enum.sort(selected_span.meta)}>
                  <span class="wf-detail-k">{k}:</span> {format_val(v)}
                </span>
              </div>
            </div>
          <% end %>
        </div>
      <% else %>
        <div class="wf-legend">
          <span class="wf-swatch"><span class="wf-box kind-client"></span>Browser step</span>
          <span class="wf-swatch"><span class="wf-box kind-cloudflare"></span>Cloudflare HTTP</span>
          <span class="wf-swatch"><span class="wf-box kind-peer"></span>Worker peer connect</span>
          <span class="wf-swatch"><span class="wf-box kind-outlet"></span>Outlet live</span>
          <span class="wf-swatch"><span class="wf-box kind-pull"></span>Track pull</span>
          <span class="wf-swatch"><span class="wf-box kind-failure"></span>Failure</span>
        </div>

        <div :if={@visible_joins == []} class="wf-empty">
          No room joins recorded yet. Join a room to see browser, Cloudflare, and worker startup waterfalls.
        </div>

        <div :for={j <- @visible_joins} class="wf-card">
          <% total_span = max(j.t_end_ms - j.t0_ms, 10.0) %>
          <div class="wf-card-head">
            <div class="wf-title">
              <span class="wf-time">{fmt_time(j.wall_at)}</span>
              <span class="wf-room">{j.room_id}</span>
              <span class="wf-speaker">Room join ({length(j.spans)} events)</span>
            </div>
            <div class="wf-totals">
              <span class="wf-pill">{round(total_span)} ms window</span>
            </div>
          </div>

          <div class="wf-ruler">
            <div class="wf-ruler-left">Event</div>
            <div class="wf-ruler-track">
              <span class="wf-tick first" style="left: 0%;">0 ms</span>
              <span class="wf-tick" style="left: 25%;">{round(total_span * 0.25)} ms</span>
              <span class="wf-tick" style="left: 50%;">{round(total_span * 0.50)} ms</span>
              <span class="wf-tick" style="left: 75%;">{round(total_span * 0.75)} ms</span>
              <span class="wf-tick last" style="left: 100%;">{round(total_span)} ms</span>
            </div>
          </div>

          <div class="wf-lane">
            <div class="wf-lane-meta">
              <div class="wf-agent">Timeline</div>
              <div class="wf-why">relative to first event</div>
            </div>
            <div class="wf-lane-bars">
              <div class="wf-gridline" style="left: 25%;"></div>
              <div class="wf-gridline" style="left: 50%;"></div>
              <div class="wf-gridline" style="left: 75%;"></div>

              <div :for={span <- j.spans} class="wf-row">
                <% left = pct(span.start_ms - j.t0_ms, total_span) %>
                <% width = max(pct(span.duration_ms, total_span), 0.5) %>
                <% selected? = @selected == {"j-#{j.id}", span.id} %>
                <button
                  type="button"
                  phx-click="select_span"
                  phx-value-card={"j-#{j.id}"}
                  phx-value-span={span.id}
                  class={"wf-bar-btn kind-#{span.kind} status-#{span.status} #{if selected?, do: "selected"}"}
                  style={"left: #{left}%; width: #{width}%;"}
                  title={"#{span.label} — #{fmt_ms(span.duration_ms)}"}
                >
                  <span class={"wf-bar-label #{if left + width > 72, do: "left-side"}"}>
                    {span.label} · {fmt_ms(span.duration_ms)}
                  </span>
                </button>
              </div>
            </div>
          </div>

          <%= if selected_span = find_selected_join_span(j, @selected) do %>
            <div class="wf-detail">
              <div><strong>{selected_span.label}</strong> ({fmt_ms(selected_span.duration_ms)})</div>
              <div class="wf-detail-grid">
                <span :for={{k, v} <- Enum.sort(selected_span.meta)}>
                  <span class="wf-detail-k">{k}:</span> {format_val(v)}
                </span>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # -- View helpers --

  defp resolve_call_id(:all, _calls), do: :all
  defp resolve_call_id(:latest, [first | _]), do: first.id
  defp resolve_call_id(:latest, []), do: :all

  defp resolve_call_id(id, calls) when is_integer(id) do
    if Enum.any?(calls, &(&1.id == id)), do: id, else: resolve_call_id(:latest, calls)
  end

  defp filter_by_call(items, :all), do: items
  defp filter_by_call(items, call_id), do: Enum.filter(items, &(&1.call_id == call_id))

  defp fmt_call_duration(%{status: :live}), do: "live"

  defp fmt_call_duration(%{started_ms: s, ended_ms: e}) when is_number(s) and is_number(e) do
    secs = max(round((e - s) / 1_000), 0)

    if secs >= 60,
      do: "#{div(secs, 60)}m #{rem(secs, 60)}s",
      else: "#{secs}s"
  end

  defp fmt_call_duration(_), do: "ended"

  defp sorted_lanes(lanes) do
    Enum.sort_by(lanes, fn {agent_id, lane} ->
      {if(lane.latency != nil, do: 0, else: 1), agent_id}
    end)
  end

  defp reply_lane(utterance) do
    utterance.lanes
    |> Map.values()
    |> Enum.find(&(&1.latency != nil))
  end

  defp find_selected_span(u, {card, span_id}) do
    if card == "u-#{u.id}" do
      Enum.find_value(u.lanes, fn {_id, lane} -> Enum.find(lane.spans, &(&1.id == span_id)) end)
    end
  end

  defp find_selected_span(_u, _selected), do: nil

  defp find_selected_join_span(j, {card, span_id}) do
    if card == "j-#{j.id}", do: Enum.find(j.spans, &(&1.id == span_id))
  end

  defp find_selected_join_span(_j, _selected), do: nil

  defp span_caption(%{kind: :llm, first_output_ms: ttft} = span) when is_number(ttft) do
    "#{span.label} · #{round(ttft)} ms TTFT / #{round(span.duration_ms)} ms"
  end

  defp span_caption(%{kind: :tts, first_output_ms: ttfb} = span) when is_number(ttfb) do
    "#{span.label} · #{round(ttfb)} ms TTFB / #{round(span.duration_ms)} ms"
  end

  defp span_caption(%{kind: :live, meta: %{audio_ms: audio_ms}} = span)
       when is_number(audio_ms) and audio_ms > 0 do
    "#{span.label} · #{round(span.duration_ms)} ms (#{round(audio_ms)} ms audio)"
  end

  defp span_caption(%{status: status} = span) when status not in [:ok, nil] do
    "#{span.label} · #{round(span.duration_ms)} ms [#{status}]"
  end

  defp span_caption(span) do
    "#{span.label} · #{round(span.duration_ms)} ms"
  end

  defp compute_stats(utterances) do
    lanes = Enum.flat_map(utterances, &Map.values(&1.lanes))
    spans = Enum.flat_map(lanes, & &1.spans)

    %{
      processing_ms:
        lanes
        |> Enum.map(&(&1.latency && &1.latency[:processing_ms]))
        |> median(),
      stt_ms:
        spans
        |> Enum.filter(&(&1.kind == :stt))
        |> Enum.map(& &1.duration_ms)
        |> median(),
      decisions_ms:
        spans
        |> Enum.filter(&(&1.kind == :decisions))
        |> Enum.map(& &1.duration_ms)
        |> median(),
      llm_ttft_ms:
        spans
        |> Enum.filter(&(&1.kind == :llm and is_number(&1.first_output_ms)))
        |> Enum.map(& &1.first_output_ms)
        |> median(),
      tts_ttfb_ms:
        spans
        |> Enum.filter(&(&1.kind == :tts and is_number(&1.first_output_ms)))
        |> Enum.map(& &1.first_output_ms)
        |> median()
    }
  end

  defp median(values) do
    nums = values |> Enum.filter(&is_number/1) |> Enum.sort()

    case nums do
      [] -> nil
      list -> Enum.at(list, div(length(list), 2))
    end
  end

  defp pct(part, total) when total > 0 do
    (part / total * 100.0) |> max(0.0) |> min(100.0) |> Float.round(2)
  end

  defp pct(_, _), do: 0.0

  defp fmt_ms(nil), do: "—"
  defp fmt_ms(ms) when is_number(ms), do: "#{round(ms)} ms"

  defp fmt_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp fmt_time(_), do: ""

  defp format_val(v) when is_binary(v), do: v
  defp format_val(v) when is_atom(v), do: Atom.to_string(v)
  defp format_val(v) when is_number(v), do: to_string(v)
  defp format_val(v), do: inspect(v)
end
