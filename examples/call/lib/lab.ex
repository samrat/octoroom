defmodule Call.Agent do
  @moduledoc """
  The call assistant's settings, kept in the room's `:agent` assign so
  everyone in the room shares them, and how they become `agent/3` options
  for `Call.Assistant`. Changing them restarts the assistant (new args),
  which starts its conversation afresh.
  """

  @defaults %{
    # :cascaded (Soniox STT, the LLM reads text) or :half (the LLM hears audio)
    pipeline: :cascaded,
    # :name (its name or a follow-up) or :decision (a decision model on the audio)
    gate: :name,
    follow_up_s: 10,
    reply_above: 0.7,
    wait_above: 0.35,
    answer_above: 0.7,
    wait_s: 2.5
  }

  def defaults, do: @defaults

  @doc "The settings in a room's assigns, over the defaults."
  def config(assigns), do: Map.merge(@defaults, Map.get(assigns, :agent) || %{})

  @doc "`Octoroom.Agent.agent/3` options for `config` (`Call.Assistant` reads `args`)."
  def opts(config) do
    [
      name: "Assistant",
      # Even alone in the call, so it behaves the same with one person or ten.
      respond: :addressed,
      gate: config.gate,
      follow_up_ms: round(config.follow_up_s * 1_000),
      thresholds: %{
        reply_above: config.reply_above,
        wait_above: config.wait_above,
        answer_above: config.answer_above,
        wait_ms: round(config.wait_s * 1_000)
      },
      args: %{pipeline: config.pipeline}
    ]
  end

  @doc "Settings from the lab's form; anything unexpected keeps its current value."
  def parse(params, current) do
    %{
      pipeline:
        choice(params["pipeline"], %{"cascaded" => :cascaded, "half" => :half}, current.pipeline),
      gate: choice(params["gate"], %{"name" => :name, "decision" => :decision}, current.gate),
      follow_up_s: number(params["follow_up_s"], 0, 30, current.follow_up_s),
      reply_above: number(params["reply_above"], 0, 1, current.reply_above),
      wait_above: number(params["wait_above"], 0, 1, current.wait_above),
      answer_above: number(params["answer_above"], 0, 1, current.answer_above),
      wait_s: number(params["wait_s"], 0.5, 10, current.wait_s)
    }
  end

  defp choice(value, allowed, default), do: Map.get(allowed, value, default)

  defp number(value, min, max, default) when is_binary(value) do
    case Float.parse(value) do
      {n, _} -> n |> max(min) |> min(max) |> Float.round(2)
      :error -> default
    end
  end

  defp number(_value, _min, _max, default), do: default
end

defmodule Call.LabLive do
  @moduledoc """
  The agent lab: join the call, switch the assistant's pipeline and how it
  decides to answer, and watch each turn's decision, the conversation and
  latency. The room is the same one `/r/<room>` shows.
  """
  use Phoenix.LiveView
  import Call.Components

  @feed_size 30

  @impl true
  def mount(params, _session, socket) do
    room = params["room"] || "lobby"

    if connected?(socket) do
      Octoroom.subscribe(room, scope: :room)
      # Assign changes (assistant on/off, settings) send no room event.
      :timer.send_interval(1_000, :refresh)
    end

    socket =
      assign(socket,
        room: room,
        me: nil,
        available?: Call.Room.assistant_available?(),
        feed: [],
        # The settings this page shows. They live in the room's `:agent`
        # assign, which only exists while the room runs: changed before
        # anyone joins (or after everyone left), they wait here, `pending`,
        # and go to the room when it starts.
        config: Call.Agent.defaults(),
        pending: false,
        pending_latency: nil,
        waiting: nil,
        follow_up: nil,
        countdown: 0
      )

    {:ok, load(socket)}
  end

  # -- Room and assistant events

  @impl true
  def handle_info({:octoroom, _room, {:worker_event, "assistant", {:agent, event}}}, socket),
    do: {:noreply, agent_event(socket, event)}

  def handle_info({:octoroom, _room, _event}, socket), do: {:noreply, load(socket)}
  def handle_info(:tick, socket), do: {:noreply, tick(socket)}
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  @impl true
  def handle_event("client", %{"state" => state} = params, socket) do
    me = if state == "joined", do: params["participant_id"]
    {:noreply, socket |> assign(me: me) |> load()}
  end

  def handle_event("toggle_assistant", _params, socket) do
    on = not on?(socket)

    case Octoroom.Room.assign(socket.assigns.room, :assistant, on) do
      {:error, :no_room} ->
        {:noreply, socket}

      _ok ->
        room_assigns = Map.put(socket.assigns.room_assigns, :assistant, on)

        {:noreply,
         assign(socket, room_assigns: room_assigns, feed: [], waiting: nil, follow_up: nil)}
    end
  end

  def handle_event("settings", params, socket),
    do: {:noreply, save(socket, Call.Agent.parse(params, socket.assigns.config))}

  def handle_event("reset", _params, socket),
    do: {:noreply, save(socket, Call.Agent.defaults())}

  # From the page's latency probe: your mic going quiet to the assistant's
  # audio arriving in this tab.
  def handle_event("heard_latency", %{"ms" => ms}, socket) when is_number(ms),
    do: {:noreply, update_last_reply(socket, &Map.put(&1, :browser_ms, round(ms)))}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp on?(socket), do: socket.assigns.room_assigns[:assistant] == true

  # Shows `config` at once, and stores it in the room if it's running.
  defp save(socket, config) do
    pending =
      case Octoroom.Room.assign(socket.assigns.room, :agent, config) do
        {:error, :no_room} -> true
        _ok -> false
      end

    assign(socket, config: config, pending: pending)
  end

  defp load(socket) do
    case Octoroom.Room.state(socket.assigns.room) do
      %{} = s ->
        socket = assign(socket, participants: s.participants, room_assigns: s.assigns)

        cond do
          # Settings made while the room wasn't running: hand them over.
          socket.assigns.pending -> save(socket, socket.assigns.config)
          Map.has_key?(s.assigns, :agent) -> assign(socket, config: Call.Agent.config(s.assigns))
          true -> socket
        end

      {:error, :no_room} ->
        # Keep whatever settings the page has; there's no room to read.
        assign(socket, participants: [], room_assigns: %{})
    end
  end

  # -- The feed: one entry per turn (with its decision) and per reply

  defp agent_event(socket, {:decision, d}) do
    entry = %{
      kind: :turn,
      source: d.source,
      speaker: d.speaker,
      text: d.text,
      outcome: d.outcome,
      why: d.why,
      decision: d.decision
    }

    push(socket, entry)
  end

  # A half-cascaded turn's transcript comes later: fill in its text.
  defp agent_event(socket, {:conversation, %{role: "user"} = item}) do
    source = Map.get(item, :source)

    case Enum.find_index(
           socket.assigns.feed,
           &(&1.kind == :turn and &1.source == source and &1.text == nil)
         ) do
      nil -> socket
      i -> assign(socket, feed: List.update_at(socket.assigns.feed, i, &%{&1 | text: item.text}))
    end
  end

  # A spoken reply comes as "playing" first, then again (same message_id)
  # once it's known how much of it was heard.
  defp agent_event(socket, {:conversation, %{role: "assistant"} = item}) do
    id = Map.get(item, :message_id)
    feed = socket.assigns.feed

    case Enum.find_index(feed, &(&1.kind == :reply and id != nil and &1.message_id == id)) do
      nil ->
        entry = %{
          kind: :reply,
          message_id: id,
          text: item.text,
          status: item.status,
          latency: socket.assigns.pending_latency,
          browser_ms: nil
        }

        socket |> assign(pending_latency: nil) |> push(entry)

      i ->
        update = &%{&1 | text: item.text, status: item.status}
        assign(socket, feed: List.update_at(feed, i, update))
    end
  end

  defp agent_event(socket, {:latency, latency}), do: assign(socket, pending_latency: latency)

  defp agent_event(socket, {:waiting, nil}), do: assign(socket, waiting: nil) |> tick()

  defp agent_event(socket, {:waiting, %{speaker: speaker, ms: ms}}),
    do: socket |> assign(waiting: %{speaker: speaker, until: now() + ms}) |> start_ticking()

  defp agent_event(socket, {:follow_up, nil}), do: assign(socket, follow_up: nil)

  defp agent_event(socket, {:follow_up, %{speaker: speaker, ms: ms}}),
    do: socket |> assign(follow_up: %{speaker: speaker, until: now() + ms}) |> start_ticking()

  defp agent_event(socket, _event), do: socket

  defp status_note("playing"), do: " (speaking…)"
  defp status_note("interrupted"), do: " (interrupted)"
  defp status_note(_status), do: ""

  defp push(socket, entry),
    do: assign(socket, feed: Enum.take(socket.assigns.feed ++ [entry], -@feed_size))

  defp update_last_reply(socket, fun) do
    feed = socket.assigns.feed

    case Enum.find_index(Enum.reverse(feed), &(&1.kind == :reply)) do
      nil -> socket
      i -> assign(socket, feed: List.update_at(feed, length(feed) - 1 - i, fun))
    end
  end

  # -- Countdowns (the wait for someone else to answer, the follow-up window)

  defp now, do: System.monotonic_time(:millisecond)

  defp start_ticking(socket) do
    if socket.assigns.countdown == 0, do: Process.send_after(self(), :tick, 250)
    assign(socket, countdown: 1) |> tick_values()
  end

  defp tick(socket) do
    socket = tick_values(socket)

    if socket.assigns.waiting || socket.assigns.follow_up do
      Process.send_after(self(), :tick, 250)
      socket
    else
      assign(socket, countdown: 0)
    end
  end

  defp tick_values(socket) do
    expire = fn
      %{until: until} = c ->
        if until > now(), do: Map.put(c, :left, Float.round((until - now()) / 1000, 1))

      nil ->
        nil
    end

    assign(socket,
      waiting: expire.(socket.assigns.waiting),
      follow_up: expire.(socket.assigns.follow_up)
    )
  end

  # -- Rendering

  defp why(:name), do: "said its name"
  defp why(:follow_up), do: "follow-up"
  defp why(:addressed), do: "model: addressed"
  defp why(:maybe_addressed), do: "model: maybe addressed"
  defp why(:open_question), do: "model: open question"
  defp why(:not_addressed), do: "not addressed"
  defp why(:always), do: "always"
  defp why(:never), do: "never"
  defp why(other), do: to_string(other)

  defp pct(nil), do: "—"
  defp pct(p), do: "#{round(p * 100)}%"

  # From the end of the addressee's speech. "decided" is when the turn went
  # to the LLM: the transcript, the decision, and any wait.
  defp latency(nil), do: nil

  defp latency(l) do
    llm = if l.llm, do: "#{l.llm} ms", else: "—"
    "decided #{l.transcript} ms · llm #{llm} · first audio #{l.audio} ms"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main>
      <h1>Agent lab · “{@room}”</h1>
      <p class="sub">
        The same room as <a href={path(@room, "")}>the call page</a>. Join, turn the assistant on,
        and talk to it — or to someone else — and watch what it decides.
      </p>

      <.call_controls room={@room} />

      <p :if={!@available?} class="empty">
        The assistant needs SONIOX_API_KEY, GOOGLE_API_KEY and INWORLD_API_KEY (see the README).
      </p>

      <div :if={@available?} class="status-row">
        <button phx-click="toggle_assistant" disabled={@participants == []}>
          {if @room_assigns[:assistant], do: "Assistant off", else: "Assistant on"}
        </button>
        <span :if={@participants == []} class="hint">Join the call first: the room starts when someone joins.</span>
        <span :if={@room_assigns[:assistant] && @waiting} class="pill live">
          Waiting to see if anyone answers {@waiting.speaker} · {@waiting.left} s
        </span>
        <span :if={@room_assigns[:assistant] && !@waiting && @follow_up} class="pill live">
          Listening for a follow-up from {@follow_up.speaker} · {@follow_up.left} s
        </span>
        <span :if={@room_assigns[:assistant] && !@waiting && !@follow_up} class="pill">
          Say “Assistant, …” to ask something
        </span>
        <span class="hint">
          {length(@participants)} in the call. Use headphones: the assistant leaking into your mic sounds like you.
        </span>
      </div>

      <div :if={@available?} class="lab">
        <form class="panel" phx-change="settings">
          <h2>Settings</h2>

          <fieldset>
            <legend>Pipeline</legend>
            <label class="opt">
              <input
                type="radio"
                name="pipeline"
                value="cascaded"
                checked={@config.pipeline == :cascaded}
              /> Cascaded <small>Soniox transcribes each person; the LLM reads text.</small>
            </label>
            <label class="opt">
              <input type="radio" name="pipeline" value="half" checked={@config.pipeline == :half} />
              Half-cascaded
              <small>
                Each turn is recorded (Smart Turn ends it) and the LLM hears the audio. A transcript follows.
              </small>
            </label>
          </fieldset>

          <fieldset>
            <legend>Deciding to answer</legend>
            <label class="opt">
              <input type="radio" name="gate" value="name" checked={@config.gate == :name} />
              Name only <small>“Assistant”, or a follow-up from the person it just answered.</small>
            </label>
            <label class="opt">
              <input type="radio" name="gate" value="decision" checked={@config.gate == :decision} />
              Decision model
              <small>
                Also asks gemini-decision-1 about each turn's audio: who it's for, and whether it can answer.
              </small>
            </label>
            <span :if={@config.pipeline == :half && @config.gate == :name} class="note">
              Half-cascaded turns are audio, so the name can't be read until the transcript arrives:
              only follow-ups count. Use the decision model.
            </span>
          </fieldset>

          <fieldset>
            <legend>Tuning</legend>
            <label class="range">
              <span>Follow-up window (s)</span>
              <input
                type="range"
                name="follow_up_s"
                min="0"
                max="30"
                step="1"
                value={@config.follow_up_s}
                phx-debounce="400"
              />
              <output>{@config.follow_up_s}</output>
            </label>
            <div :if={@config.gate == :decision}>
              <label class="range">
                <span>Reply when “for the assistant” is at least</span>
                <input
                  type="range"
                  name="reply_above"
                  min="0"
                  max="1"
                  step="0.05"
                  value={@config.reply_above}
                  phx-debounce="400"
                />
                <output>{pct(@config.reply_above)}</output>
              </label>
              <label class="range">
                <span>…or wait, then reply, from</span>
                <input
                  type="range"
                  name="wait_above"
                  min="0"
                  max="1"
                  step="0.05"
                  value={@config.wait_above}
                  phx-debounce="400"
                />
                <output>{pct(@config.wait_above)}</output>
              </label>
              <label class="range">
                <span>Open question it can answer, at least</span>
                <input
                  type="range"
                  name="answer_above"
                  min="0"
                  max="1"
                  step="0.05"
                  value={@config.answer_above}
                  phx-debounce="400"
                />
                <output>{pct(@config.answer_above)}</output>
              </label>
              <label class="range">
                <span>Wait for someone else to answer (s)</span>
                <input
                  type="range"
                  name="wait_s"
                  min="0.5"
                  max="10"
                  step="0.5"
                  value={@config.wait_s}
                  phx-debounce="400"
                />
                <output>{@config.wait_s}</output>
              </label>
            </div>
          </fieldset>

          <p class="note">
            Changing a setting restarts the assistant, so it forgets the conversation.
          </p>
          <button type="button" class="secondary" phx-click="reset">Reset to defaults</button>
        </form>

        <section class="panel feed" id="feed">
          <h2>What it heard and decided</h2>
          <p :if={@feed == []} class="empty">
            {if @room_assigns[:assistant],
              do: "Listening. Say something…",
              else: "Turn the assistant on to start."}
          </p>
          <div :for={e <- @feed} class="entry">
            <%= if e.kind == :turn do %>
              <div>
                <span class="who">{e.speaker}:</span>
                {e.text || "(audio; transcript to follow)"}
              </div>
              <div class="chips">
                <span class={["chip", to_string(e.outcome)]}>{e.outcome} · {why(e.why)}</span>
                <span :if={e.decision} class="chip">to {e.decision.addressee} {pct(
                  e.decision.confidence
                )}</span>
                <span :if={e.decision} class="chip">assistant {pct(
                  e.decision.probabilities["assistant"]
                )}</span>
                <span :if={e.decision} class="chip">answerable {pct(e.decision.answerable)}</span>
                <span :if={e.decision} class="chip">{e.decision.latency_ms} ms</span>
              </div>
            <% else %>
              <div>
                <span class="who">Assistant:</span>
                {e.text}{status_note(e.status)}
              </div>
              <div :if={e.latency || e.browser_ms} class="latency">
                {latency(e.latency)}{if e.browser_ms, do: " · heard in browser #{e.browser_ms} ms"}
              </div>
            <% end %>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
