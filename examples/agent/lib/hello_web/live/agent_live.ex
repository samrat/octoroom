defmodule HelloWeb.AgentLive do
  @moduledoc """
  A 1-on-1 Voice Stage + Workbench demo. The browser joins the room and drives
  the living presence orb, 2-lane Voice Timeline, captions, and transcript with
  `octoroom_agents.mjs` (see `assets/js/agent.js`). This LiveView feeds live
  partials and latency stage breakdowns from `Octoroom.subscribe/2` alongside
  the tab-measured `Heard` latency table.

  Each page opens its own room, so the agent only ever talks to one person.
  """
  use HelloWeb, :live_view

  @dev_routes? Application.compile_env(:hello, :dev_routes, false)

  @impl true
  def mount(_params, _session, socket) do
    room = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    if connected?(socket) do
      Octoroom.subscribe(room, scope: :room)
      Phoenix.PubSub.subscribe(Hello.PubSub, "clinic:#{room}")
      Phoenix.PubSub.subscribe(Hello.PubSub, HelloWeb.TraceStore.room_topic(room))
    end

    pipeline = Hello.Assistant.default_pipeline()

    {:ok,
     socket
     |> assign(
       room: room,
       pipelines: Hello.Assistant.pipelines(),
       active_tool: nil,
       questions: Enum.with_index(Hello.Questions.all()),
       greeting: nil,
       replies: [],
       asked: nil,
       typing: false,
       pending: %{latency: nil, heard: nil}
     )
     |> assign_pipeline(pipeline)}
  end

  @impl true
  def handle_info({:octoroom, _room, {:worker_event, "assistant", {:agent, event}}}, socket),
    do: {:noreply, agent_event(socket, event)}

  def handle_info({:tool_event, ev}, socket) do
    payload = %{
      id: ev.id,
      name: ev.name,
      status: ev.status,
      duration_ms: ev[:duration_ms],
      args_text: format_tool_args(ev.args),
      result_text: format_tool_result(ev)
    }

    {:noreply,
     socket
     |> assign(active_tool: ev)
     |> push_event("tool_call", payload)}
  end

  def handle_info({:appointments_updated, appointments}, socket),
    do: {:noreply, assign(socket, appointments: appointments)}

  # Pipeline stage spans from TraceStore (STT, decisions, floor wait, LLM, tools, TTS, live).
  def handle_info({:timeline_spans, spans}, socket),
    do: {:noreply, push_event(socket, "timeline_event", %{type: "stage_spans", spans: spans})}

  def handle_info({:octoroom, _room, _event}, socket), do: {:noreply, socket}

  # From the page: your mic going quiet to the agent's voice arriving. It
  # can come before the reply's "playing" item does.
  @impl true
  def handle_event("heard", %{"ms" => ms}, socket) when is_number(ms),
    do: {:noreply, attach(socket, :heard, round(ms))}

  # From the page: after joining, when the agent's track arrived and when
  # its greeting was first heard.
  def handle_event("greeting", %{"track" => track, "sound" => sound}, socket),
    do: {:noreply, assign(socket, greeting: %{track: round(track), sound: round(sound)})}

  def handle_event("select_pipeline", %{"pipeline" => id}, socket) do
    if Hello.Assistant.valid_pipeline?(id) do
      info = Hello.Assistant.pipeline_info(id)
      switched_live? = Octoroom.Room.assign(socket.assigns.room, :pipeline, id) == :ok

      socket = assign_pipeline(socket, id)

      socket =
        if switched_live?,
          do: push_event(socket, "pipeline_switched", %{name: info.name}),
          else: socket

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp assign_pipeline(socket, id) do
    info = Hello.Assistant.pipeline_info(id)
    booking? = info.agent == Hello.Booking
    agent_name = if booking?, do: "Elixir Clinic Booking", else: "Elixir Clinic"
    tools = if booking?, do: [], else: Hello.Assistant.tool_names()

    assign(socket,
      pipeline: info.id,
      agent_name: agent_name,
      agent_initial: agent_name |> String.first() |> String.upcase(),
      pipeline_label: info.label,
      tools: tools,
      appointments:
        if(tools != [], do: Hello.Clinic.list_appointments(socket.assigns.room), else: [])
    )
  end

  # Live partial transcripts power the streaming caption under the presence orb.
  defp agent_event(socket, {:transcription, %{text: text}}) when is_binary(text),
    do: push_event(socket, "partial", %{text: text})

  # A typed turn is decided as `:typed` just before it joins the conversation.
  defp agent_event(socket, {:decision, %{why: :typed}}), do: assign(socket, typing: true)

  # What you said, then the reply to it. A spoken reply comes twice with
  # the same message_id: "playing", then "completed" or "interrupted".
  defp agent_event(socket, {:conversation, %{role: "user"} = item}),
    do: assign(socket, asked: %{text: item.text, typed: socket.assigns.typing}, typing: false)

  defp agent_event(socket, {:conversation, %{role: "assistant"} = item}) do
    id = Map.get(item, :message_id)

    socket =
      if Map.get(item, :status) == "interrupted",
        do: push_event(socket, "timeline_event", %{type: "interruption", agent: "assistant"}),
        else: socket

    case Enum.find_index(socket.assigns.replies, &(&1.id == id)) do
      # Nobody has spoken yet: the greeting.
      nil when socket.assigns.asked == nil ->
        socket

      nil ->
        %{asked: asked, pending: pending} = socket.assigns

        reply = %{
          id: id,
          asked: asked.text,
          typed: asked.typed,
          text: item.text,
          latency: pending.latency,
          heard: if(asked.typed, do: nil, else: pending.heard)
        }

        assign(socket,
          replies: [reply | socket.assigns.replies],
          asked: nil,
          pending: %{latency: nil, heard: nil}
        )

      i ->
        update_reply(socket, i, &%{&1 | text: item.text})
    end
  end

  # Sent when the reply's first audio goes to the outlet.
  defp agent_event(socket, {:latency, latency}) when is_map(latency) do
    socket
    |> attach(:latency, latency)
    |> push_event("timeline_event", %{
      type: "reply_latency",
      agent: "assistant",
      audio_ms: latency[:audio]
    })
  end

  defp agent_event(socket, _event), do: socket

  # Puts a timing on the newest reply if it's still missing it and nobody
  # has spoken since; otherwise keeps it for the reply that's coming.
  defp attach(socket, key, value) do
    case socket.assigns.replies do
      [%{^key => nil, typed: typed} | _]
      when socket.assigns.asked == nil and (key == :latency or not typed) ->
        update_reply(socket, 0, &Map.put(&1, key, value))

      _ ->
        assign(socket, pending: Map.put(socket.assigns.pending, key, value))
    end
  end

  defp update_reply(socket, i, fun),
    do: assign(socket, replies: List.update_at(socket.assigns.replies, i, fun))

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp ms(nil), do: "—"
  defp ms(n), do: "#{n} ms"

  defp format_tool_args(args) when is_map(args) and map_size(args) > 0 do
    args
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{format_arg_val(v)}" end)
  end

  defp format_tool_args(_), do: "no args"

  defp format_arg_val(v) when is_binary(v), do: ~s("#{v}")
  defp format_arg_val(v), do: to_string(v)

  defp format_tool_result(%{status: "running"}), do: "running…"

  defp format_tool_result(%{response: %{message: msg}}) when is_binary(msg), do: msg

  defp format_tool_result(%{response: %{date_label: label, available_slots: slots}}) do
    times = Enum.map_join(slots, ", ", & &1.time)
    "#{label} · #{length(slots)} open (#{times})"
  end

  defp format_tool_result(%{response: %{result: "booked", appointment: appt}}) do
    "Booked #{appt.code} · #{appt.date_label} #{appt.time} with #{appt.doctor}"
  end

  defp format_tool_result(%{response: %{result: "cancelled", cancelled: appt}}) do
    "Cancelled #{appt.code} (#{appt.date_label} #{appt.time})"
  end

  defp format_tool_result(%{response: %{appointments: []}}), do: "No appointments booked"

  defp format_tool_result(%{response: %{appointments: appts}}) when is_list(appts) do
    "#{length(appts)} booked (#{Enum.map_join(appts, ", ", & &1.code)})"
  end

  defp format_tool_result(%{response: resp}), do: inspect(resp)
  defp format_tool_result(_), do: ""

  defp reply_bar_segments(reply) do
    total = reply.heard || (reply.latency && reply.latency.audio) || 0

    if total <= 0 do
      []
    else
      stt = if reply.typed, do: 0, else: (reply.latency && reply.latency.transcript) || 0
      llm_end = (reply.latency && reply.latency.llm) || stt
      audio_end = (reply.latency && reply.latency.audio) || llm_end

      llm = max(llm_end - stt, 0)
      tts = max(audio_end - llm_end, 0)
      ear = if is_integer(reply.heard), do: max(reply.heard - audio_end, 0), else: 0

      [
        {"stt", "#64748b", stt},
        {"llm", "#4f46e5", llm},
        {"tts", "#10b981", tts},
        {"sfu + ear", "rgba(148,163,184,0.45)", ear}
      ]
      |> Enum.filter(fn {_label, _color, d} -> d > 0 end)
      |> Enum.map(fn {label, color, d} ->
        %{label: label, color: color, ms: d, pct: Float.round(d / total * 100, 1)}
      end)
    end
  end

  @impl true
  def render(assigns) do
    heard = for %{heard: h} when is_integer(h) <- assigns.replies, do: h
    server = for %{latency: %{audio: a}} when is_integer(a) <- assigns.replies, do: a

    assigns =
      assign(assigns,
        dev_routes?: @dev_routes?,
        median: median(heard),
        median_server: median(server),
        count: length(heard)
      )

    ~H"""
    <Layouts.app flash={@flash} fluid>
      <div
        id="agent"
        phx-hook="Agent"
        data-room={@room}
        data-pipeline={@pipeline}
        data-agent-name={@agent_name}
        data-agent-initial={@agent_initial}
        class="flex h-full flex-col bg-base-300 text-base-content"
      >
        <%!-- Session Header --%>
        <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 bg-base-100 px-4 py-2.5 sm:px-6">
          <div class="flex flex-wrap items-center gap-3">
            <div class="flex items-center gap-2">
              <span class="flex size-7 items-center justify-center rounded-lg bg-gradient-to-br from-primary to-info text-xs font-bold text-primary-content">
                {@agent_initial}
              </span>
              <div>
                <h1 class="text-sm font-semibold leading-tight">{@agent_name}</h1>
                <p id="pipeline-label" class="font-mono text-[11px] opacity-55">{@pipeline_label}</p>
              </div>
            </div>

            <form phx-change="select_pipeline" class="flex items-center">
              <label for="pipeline-select" class="sr-only">Pipeline</label>
              <select
                id="pipeline-select"
                name="pipeline"
                aria-label="Pipeline"
                class="select select-xs border-base-300 bg-base-200 font-mono text-[11px]"
              >
                <option :for={p <- @pipelines} value={p.id} selected={p.id == @pipeline}>
                  {p.name}
                </option>
              </select>
            </form>

            <div
              id="connection-pill"
              phx-update="ignore"
              class="flex items-center gap-2 rounded-full border border-base-300 bg-base-200 px-2.5 py-1 text-xs"
            >
              <span data-live-dot class="size-2 rounded-full bg-base-content/30"></span>
              <span id="state" class="badge badge-sm badge-ghost">not joined</span>
              <span data-call-clock class="font-mono text-[11px] opacity-60">00:00</span>
            </div>
          </div>

          <div class="flex items-center gap-1.5">
            <button
              id="toggle-timeline"
              type="button"
              class="btn btn-ghost btn-xs font-mono text-[11px]"
              phx-click={JS.toggle(to: "#voice-timeline", display: "flex")}
            >
              <.icon name="hero-chart-bar" class="size-3.5" /> Timeline
            </button>
            <button
              id="toggle-workbench"
              type="button"
              class="btn btn-ghost btn-xs font-mono text-[11px]"
              phx-click={JS.toggle(to: "#workbench", display: "flex")}
            >
              <.icon name="hero-beaker" class="size-3.5" /> Workbench
            </button>
            <a
              :if={@dev_routes?}
              href="/dev/dashboard/octoroom"
              target="_blank"
              rel="noopener"
              class="btn btn-ghost btn-xs font-mono text-[11px]"
              title="Open LiveDashboard Octoroom waterfalls and metrics"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3.5" /> Dashboard
            </a>
            <button
              id="toggle-transcript"
              type="button"
              class="btn btn-ghost btn-xs font-mono text-[11px] lg:hidden"
              phx-click={JS.toggle(to: "#transcript-panel", display: "flex")}
            >
              <.icon name="hero-chat-bubble-bottom-center-text" class="size-3.5" /> Transcript
            </button>
          </div>
        </div>

        <%!-- Main Body: Voice Stage (left) + Transcript (right) --%>
        <div class="flex min-h-0 flex-1">
          <div class="flex min-w-0 flex-1 flex-col">
            <div class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto p-4 sm:px-6">
              <%!-- Hero Presence Stage --%>
              <div
                id="presence-stage"
                class="flex flex-1 flex-col items-center justify-center gap-3 rounded-2xl bg-base-100/70 px-6 py-8 text-center"
              >
                <div
                  id="presence-orb-stage"
                  phx-update="ignore"
                  class="flex flex-col items-center justify-center gap-3"
                >
                  <div data-agent-orb-wrap class="relative flex size-44 items-center justify-center">
                    <canvas
                      data-agent-orb
                      width="176"
                      height="176"
                      role="img"
                      aria-label="Live agent voice presence visualizer"
                      class="size-44"
                    >
                    </canvas>
                  </div>

                  <div class="relative flex items-center justify-center">
                    <video
                      data-agent-video
                      autoplay
                      playsinline
                      class="hidden aspect-video w-full max-w-md rounded-2xl border border-base-300 bg-black object-cover shadow-lg"
                    >
                    </video>

                    <video
                      data-local-video
                      muted
                      autoplay
                      playsinline
                      class="hidden h-24 w-32 -scale-x-100 rounded-xl border border-base-300 bg-black object-cover shadow-md"
                    >
                    </video>
                  </div>

                  <span
                    data-stage-state
                    class="rounded-full border border-base-300 bg-base-100 px-3 py-1 font-mono text-xs font-medium text-base-content/75"
                  >
                    Ready to talk
                  </span>

                  <div
                    data-live-caption
                    class="hidden min-h-11 max-w-lg items-center justify-center rounded-xl border border-base-300/70 bg-base-100 px-4 py-2 text-sm text-base-content"
                  >
                  </div>
                </div>

                <div
                  :if={@tools != []}
                  id="tool-chips"
                  class="flex flex-wrap items-center justify-center gap-1.5 pt-1"
                >
                  <span
                    :for={tool <- @tools}
                    class={[
                      "rounded-full border px-2.5 py-0.5 font-mono text-[10px] transition-colors",
                      if(@active_tool && @active_tool.name == tool,
                        do: "border-secondary/60 bg-secondary/15 font-semibold text-secondary",
                        else: "border-base-300 bg-base-100/80 text-base-content/55"
                      ),
                      @active_tool && @active_tool.name == tool &&
                        @active_tool.status == "running" && "animate-pulse"
                    ]}
                  >
                    {tool}
                  </span>
                </div>

                <div
                  :if={@active_tool}
                  id="active-tool"
                  class="flex max-w-lg items-center gap-2 rounded-lg border border-secondary/30 bg-secondary/10 px-3 py-1.5 font-mono text-[11px] text-base-content"
                >
                  <.icon name="hero-wrench-screwdriver" class="size-3.5 shrink-0 text-secondary" />
                  <span class="font-semibold text-secondary">{@active_tool.name}</span>
                  <span class="truncate text-base-content/75">
                    {format_tool_result(@active_tool)}
                  </span>
                  <span :if={@active_tool[:duration_ms]} class="shrink-0 opacity-60">
                    {@active_tool.duration_ms}ms
                  </span>
                </div>
              </div>

              <%!-- 2-Lane Voice Timeline (Option A look + Option B hover waterfall) --%>
              <section
                id="voice-timeline"
                phx-update="ignore"
                aria-label="Voice timeline"
                class="flex flex-col rounded-xl bg-base-100 shadow-sm"
              >
                <div class="flex flex-wrap items-center justify-between gap-2 border-b border-base-300 px-3 py-1.5 text-[11px] text-base-content/65">
                  <div class="flex flex-wrap items-center gap-3">
                    <span class="text-xs font-semibold text-base-content">Voice timeline</span>
                    <div class="join" role="group" aria-label="Time window">
                      <button
                        type="button"
                        data-timeline-window="10"
                        class="btn btn-ghost btn-xs join-item font-mono text-[10px] font-medium"
                      >
                        10s
                      </button>
                      <button
                        type="button"
                        data-timeline-window="15"
                        class="btn btn-ghost btn-xs join-item btn-active font-mono text-[10px] font-medium"
                      >
                        15s
                      </button>
                      <button
                        type="button"
                        data-timeline-window="30"
                        class="btn btn-ghost btn-xs join-item font-mono text-[10px] font-medium"
                      >
                        30s
                      </button>
                    </div>
                    <span class="hidden font-mono text-[10px] opacity-65 sm:inline">
                      Hover a reply for STT / LLM / TTS breakdown
                    </span>
                  </div>
                  <div class="flex items-center gap-1">
                    <a
                      :if={@dev_routes?}
                      href="/dev/dashboard/octoroom"
                      target="_blank"
                      rel="noopener"
                      class="btn btn-ghost btn-xs font-mono text-[10px] font-normal"
                      title="Open full turn waterfall in LiveDashboard"
                    >
                      Waterfall ↗
                    </a>
                    <button
                      type="button"
                      data-timeline-live
                      class="btn btn-warning btn-soft btn-xs hidden font-mono text-[10px] font-medium"
                      title="Jump back to live edge"
                    >
                      Live ⇥
                    </button>
                    <button
                      type="button"
                      data-timeline-pause
                      data-paused="false"
                      class="btn btn-ghost btn-xs font-mono text-[10px] font-normal"
                      title="Pause timeline"
                    >
                      <span data-timeline-pause-label>Pause</span>
                    </button>
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs btn-circle"
                      phx-click={JS.hide(to: "#voice-timeline")}
                      title="Hide voice timeline"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                </div>

                <div id="voice-timeline-body" class="relative flex gap-2.5 px-3 py-2">
                  <div data-timeline-lane-labels class="relative w-24 shrink-0 sm:w-28"></div>
                  <div class="relative min-w-0 flex-1 [mask-image:linear-gradient(to_right,transparent,black_2.25rem)]">
                    <canvas
                      data-timeline-canvas
                      role="img"
                      aria-label="Live 2-lane speech waveforms for agent and user"
                      class="block w-full"
                    >
                    </canvas>
                  </div>
                  <div
                    data-timeline-popover
                    class="pointer-events-none absolute bottom-[calc(100%+8px)] z-30 hidden max-w-sm min-w-60 rounded-xl bg-neutral px-3 py-2.5 font-mono text-[11px] text-neutral-content shadow-xl"
                  >
                  </div>
                </div>
              </section>

              <%!-- Workbench Drawer (hidden by default; toggle from header) --%>
              <section
                id="workbench"
                class="hidden flex-col gap-3 rounded-xl bg-base-100 p-4 shadow-sm"
              >
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <div class="flex items-center gap-2">
                    <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/70">
                      Workbench
                    </h2>
                    <span class="text-xs text-base-content/50">
                      Recorded probes &amp; server-vs-heard latency
                    </span>
                  </div>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs btn-circle"
                    phx-click={JS.hide(to: "#workbench")}
                    title="Hide workbench"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>

                <div id="questions" phx-update="ignore" class="flex flex-wrap items-center gap-1.5">
                  <span class="mr-1 font-mono text-[11px] text-base-content/60">
                    Recorded questions:
                  </span>
                  <button
                    :for={{q, i} <- @questions}
                    class="btn btn-xs btn-soft ask"
                    data-src={Hello.Questions.path(i)}
                    disabled
                  >
                    {q}
                  </button>
                </div>

                <div id="latency" class="space-y-2 border-t border-base-300/70 pt-3">
                  <div class="flex flex-wrap items-baseline justify-between gap-2">
                    <div class="flex flex-wrap items-baseline gap-4">
                      <p :if={@median} id="median" class="text-sm">
                        Median heard: <b class="font-mono">{@median} ms</b>
                        <span class="text-xs text-base-content/60">
                          ({@count} {if @count == 1, do: "reply", else: "replies"})
                        </span>
                      </p>
                      <p :if={@median_server} class="text-xs text-base-content/60">
                        Median server: <b class="font-mono">{@median_server} ms</b>
                      </p>
                      <p :if={!@median} class="text-xs text-base-content/55">
                        Ask a question to measure STT, LLM, TTS, and tab-heard latency.
                      </p>
                    </div>
                    <p
                      :if={@greeting}
                      id="greeting"
                      class="font-mono text-[11px] text-base-content/60"
                    >
                      Greeting: track {@greeting.track} ms · sound {@greeting.sound} ms
                    </p>
                  </div>

                  <div :if={@replies != []} class="overflow-x-auto">
                    <table class="table table-xs">
                      <thead>
                        <tr>
                          <th>Turn</th>
                          <th class="w-36">Breakdown</th>
                          <th>STT</th>
                          <th>LLM</th>
                          <th>TTS</th>
                          <th>Heard</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={r <- @replies} id={"reply-#{r.id}"}>
                          <td>
                            <div class="font-medium">{r.asked}</div>
                            <div class="text-xs text-base-content/60">{r.text}</div>
                          </td>
                          <td>
                            <div class="flex h-2 w-32 gap-px overflow-hidden rounded-full bg-base-200">
                              <span
                                :for={seg <- reply_bar_segments(r)}
                                style={"width: #{seg.pct}%; background: #{seg.color};"}
                                title={"#{seg.label}: #{seg.ms} ms"}
                              >
                              </span>
                            </div>
                          </td>
                          <td class="font-mono whitespace-nowrap">
                            {if r.typed, do: "typed", else: ms(r.latency && r.latency.transcript)}
                          </td>
                          <td class="font-mono whitespace-nowrap">
                            {ms(r.latency && r.latency.llm)}
                          </td>
                          <td class="font-mono whitespace-nowrap">
                            {ms(r.latency && r.latency.audio)}
                          </td>
                          <td class="font-mono whitespace-nowrap font-bold">{ms(r.heard)}</td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                </div>
              </section>
            </div>

            <%!-- Bottom Call Control Bar --%>
            <div
              id="call-controls"
              phx-update="ignore"
              class="flex flex-wrap items-center justify-between gap-3 border-t border-base-300 bg-base-100 px-4 py-3 sm:px-6"
            >
              <p id="status" class="min-w-0 flex-1 truncate text-xs text-base-content/60"></p>
              <div class="flex items-center gap-3">
                <.button
                  id="join"
                  variant="primary"
                  class="btn btn-primary btn-circle sm:btn-lg"
                  title="Join call"
                  aria-label="Join"
                >
                  <.icon name="hero-phone" class="size-5" />
                  <span class="sr-only">Join</span>
                </.button>
                <button
                  id="mute"
                  type="button"
                  class="btn btn-neutral btn-circle sm:btn-lg"
                  title="Mute microphone"
                  aria-label="Mute"
                  disabled
                >
                  <span data-mic-on>
                    <.icon name="hero-microphone" class="block size-5" />
                  </span>
                  <span data-mic-off class="hidden">
                    <.icon name="hero-microphone-slash" class="block size-5" />
                  </span>
                  <span data-mute-label class="sr-only">Mute</span>
                </button>
                <button
                  id="camera"
                  type="button"
                  class="btn btn-neutral btn-circle sm:btn-lg"
                  title="Share camera"
                  aria-label="Camera"
                  disabled
                >
                  <span data-cam-on class="hidden">
                    <.icon name="hero-video-camera" class="block size-5" />
                  </span>
                  <span data-cam-off>
                    <.icon name="hero-video-camera-slash" class="block size-5" />
                  </span>
                  <span data-camera-label class="sr-only">Camera</span>
                </button>
                <.button
                  id="leave"
                  class="btn btn-error btn-circle sm:btn-lg"
                  title="Leave call"
                  aria-label="Leave"
                  disabled
                >
                  <.icon name="hero-phone-x-mark" class="size-5" />
                  <span class="sr-only">Leave</span>
                </.button>
              </div>
              <div class="hidden flex-1 sm:block"></div>
            </div>
          </div>

          <%!-- Right Transcript Sidebar --%>
          <aside
            id="transcript-panel"
            class="hidden w-88 shrink-0 flex-col border-l border-base-300 bg-base-100 lg:flex max-lg:fixed max-lg:inset-x-3 max-lg:top-20 max-lg:bottom-20 max-lg:z-20 max-lg:mx-auto max-lg:w-auto max-lg:max-w-md max-lg:rounded-xl max-lg:border max-lg:shadow-2xl"
          >
            <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
              <div>
                <h2 class="text-sm font-semibold">Transcript</h2>
                <p class="text-xs opacity-55">Turns &amp; tool calls</p>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs btn-circle lg:hidden"
                phx-click={JS.hide(to: "#transcript-panel")}
                title="Close"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <div
              :if={@tools != []}
              id="clinic-sidebar"
              class="max-h-48 space-y-2 overflow-y-auto border-b border-base-300 bg-base-200/40 px-4 py-3"
            >
              <div id="appointments" class="space-y-1.5">
                <div class="flex items-center justify-between font-mono text-[10px] uppercase tracking-wide text-base-content/55">
                  <span>Appointments</span>
                  <span>{length(@appointments)}</span>
                </div>
                <p :if={@appointments == []} class="text-xs text-base-content/45">
                  No appointments scheduled.
                </p>
                <div
                  :for={appt <- @appointments}
                  id={"appt-#{appt.code}"}
                  class="flex items-center justify-between gap-2 rounded-lg border border-base-300 bg-base-100 px-2.5 py-1.5 text-xs"
                >
                  <div class="min-w-0">
                    <div class="truncate font-medium">
                      {appt.date_label} · {appt.time}
                    </div>
                    <div class="truncate text-[11px] text-base-content/60">
                      {appt.doctor} · {appt.patient_name} ({appt.reason})
                    </div>
                  </div>
                  <span class="badge badge-xs badge-ghost shrink-0 font-mono">{appt.code}</span>
                </div>
              </div>
            </div>

            <div id="transcript-scroll" phx-update="ignore" class="min-h-0 flex-1 overflow-y-auto p-4">
              <p id="transcript-empty" class="text-xs text-base-content/50">
                Join the call to start a conversation, or ask one of the recorded questions in the
                workbench.
              </p>
              <div id="transcript" class="space-y-3"></div>
            </div>

            <form
              id="say"
              phx-update="ignore"
              class="flex gap-2 border-t border-base-300 p-3"
              autocomplete="off"
            >
              <input
                id="text"
                type="text"
                placeholder="Or type to it…"
                autocomplete="off"
                class="input input-sm min-w-0 flex-1"
                disabled
              />
              <button type="submit" class="btn btn-primary btn-sm" disabled>Send</button>
            </form>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
