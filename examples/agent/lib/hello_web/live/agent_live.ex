defmodule HelloWeb.AgentLive do
  @moduledoc """
  The page. The browser joins the room and shows the agent's state and
  transcript itself, with `octoroom_agents.mjs` (see `assets/js/agent.js`).
  This LiveView shows how long each reply took: the agent's own timings,
  from `Octoroom.subscribe/2`, next to what the browser measured.

  Each page opens its own room, so the agent only ever talks to one person.
  """
  use HelloWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    room = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    if connected?(socket), do: Octoroom.subscribe(room, scope: :room)

    {:ok,
     assign(socket,
       room: room,
       questions: Enum.with_index(Hello.Questions.all()),
       greeting: nil,
       replies: [],
       asked: nil,
       typing: false,
       pending: %{latency: nil, heard: nil}
     )}
  end

  @impl true
  def handle_info({:octoroom, _room, {:worker_event, "assistant", {:agent, event}}}, socket),
    do: {:noreply, agent_event(socket, event)}

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

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # A typed turn is decided as `:typed` just before it joins the conversation.
  defp agent_event(socket, {:decision, %{why: :typed}}), do: assign(socket, typing: true)

  # What you said, then the reply to it. A spoken reply comes twice with
  # the same message_id: "playing", then "completed" or "interrupted".
  defp agent_event(socket, {:conversation, %{role: "user"} = item}),
    do: assign(socket, asked: %{text: item.text, typed: socket.assigns.typing}, typing: false)

  defp agent_event(socket, {:conversation, %{role: "assistant"} = item}) do
    id = Map.get(item, :message_id)

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
  defp agent_event(socket, {:latency, latency}), do: attach(socket, :latency, latency)

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

  @impl true
  def render(assigns) do
    heard = for %{heard: h} when is_integer(h) <- assigns.replies, do: h
    assigns = assign(assigns, median: median(heard), count: length(heard))

    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Talk to an agent
        <:subtitle>
          Join, and it greets you. Use headphones: with speakers, its voice leaks into
          your mic and sounds like you talking.
        </:subtitle>
      </.header>

      <%!-- The hook owns everything in here except the latency panel: phx-update="ignore"
           keeps LiveView from resetting what it changes. --%>
      <div id="agent" phx-hook="Agent" data-room={@room} class="space-y-4">
        <div id="call-controls" phx-update="ignore" class="flex flex-wrap items-center gap-2">
          <.button id="join" variant="primary">Join</.button>
          <.button id="leave" disabled>Leave</.button>
          <.button id="mute" disabled>Mute</.button>
          <span id="state" class="badge badge-ghost">not joined</span>
          <p id="status" class="w-full text-sm text-base-content/60"></p>
        </div>

        <div id="questions" phx-update="ignore" class="flex flex-wrap items-center gap-2">
          <span class="text-sm text-base-content/60">Ask a recorded question:</span>
          <button
            :for={{q, i} <- @questions}
            class="btn btn-sm btn-soft ask"
            data-src={Hello.Questions.path(i)}
            disabled
          >
            {q}
          </button>
        </div>

        <form id="say" phx-update="ignore" class="join w-full">
          <input
            id="text"
            type="text"
            placeholder="Or type to it…"
            autocomplete="off"
            class="input join-item flex-1"
            disabled
          />
          <button type="submit" class="btn join-item" disabled>Send</button>
        </form>

        <section>
          <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">
            Transcript
          </h2>
          <div id="transcript" phx-update="ignore" class="space-y-2"></div>
        </section>
      </div>

      <section id="latency" class="space-y-2">
        <h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
          Latency
        </h2>
        <p class="text-sm text-base-content/60">
          Milliseconds from the end of your speech. The agent measures STT, LLM and TTS:
          when the final transcript, the first LLM text and the first audio were ready.
          This tab measures Heard: from your voice going quiet to the agent's arriving.
        </p>
        <p :if={@median} id="median" class="text-lg">
          Median heard: <b>{@median} ms</b> ({@count} {if @count == 1, do: "reply", else: "replies"})
        </p>
        <p :if={@greeting} id="greeting" class="text-sm text-base-content/60">
          After joining, the agent's track arrived at {@greeting.track} ms and its greeting
          was first heard at {@greeting.sound} ms.
        </p>
        <table :if={@replies != []} class="table table-sm">
          <thead>
            <tr>
              <th>You</th>
              <th>STT</th>
              <th>LLM</th>
              <th>TTS</th>
              <th>Heard</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={r <- @replies} id={"reply-#{r.id}"}>
              <td>
                {r.asked}
                <div class="text-base-content/60">{r.text}</div>
              </td>
              <td class="font-mono whitespace-nowrap">
                {if r.typed, do: "typed", else: ms(r.latency && r.latency.transcript)}
              </td>
              <td class="font-mono whitespace-nowrap">{ms(r.latency && r.latency.llm)}</td>
              <td class="font-mono whitespace-nowrap">{ms(r.latency && r.latency.audio)}</td>
              <td class="font-mono whitespace-nowrap font-bold">{ms(r.heard)}</td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end
end
