defmodule MeetWeb.RoomLive do
  @moduledoc """
  The call page. The browser's Octoroom client (the `Call` hook in
  assets/js/call.js) carries the audio and video; this LiveView renders
  what the room server knows (who's here, what each person publishes) and
  what the assistants hear and decide, as a transcript: one entry per turn,
  with a row of tags for each assistant's decision. Each assistant's tile
  shows the state it reports itself (its presence: listening, thinking,
  speaking, waiting), and anyone in the call can type to an assistant
  from the box under the transcript (the `Call` hook sends it with the
  browser client's `room.send/2`).

  The assistants save their conversations, so the transcript is rebuilt
  from them when the call appears: after the server restarts (LiveView
  mounts again) and for someone who joins mid-call. Decisions aren't saved:
  rebuilt turns have no tags.
  """
  use MeetWeb, :live_view

  @impl true
  def mount(params, _session, socket) do
    room = params["room"] || "lobby"

    if connected?(socket) do
      Octoroom.subscribe(room, scope: :room)
      Phoenix.PubSub.subscribe(Meet.PubSub, "theme:#{room}")
    end

    socket =
      socket
      |> assign(
        room: room,
        page_title: room,
        me: nil,
        joining: false,
        form: to_form(%{"name" => "", "camera" => "true"}),
        assistants: Meet.Room.assistants(),
        # Each assistant's presence: :listening, :thinking, :waiting or
        # :speaking
        states: %{},
        # Who the type box sends to, so a re-render keeps the choice
        say_to: nil,
        # Who each assistant is waiting on: %{id => speaker}
        waiting: %{},
        # Words still arriving, by mic: %{source => %{speaker, text}}
        partials: %{},
        turns: 0,
        # The latest turn from each mic, so the other assistants' decisions
        # on it join it: %{source => entry}
        last_turns: %{},
        # Decisions from the other assistants that came before the first
        # assistant's turn they belong to: %{source => [verdict]}
        early: %{},
        reply_times: %{}
      )
      |> stream(:transcript, [])

    {:ok, load(socket)}
  end

  # The conversation so far, from what the assistants saved: the primary's
  # turns (or another's, if it has none) and every assistant's replies.
  # Entries already shown are replaced: the saved ones include them.
  defp restore_transcript(socket) do
    %{room: room, assistants: assistants} = socket.assigns
    saved = for a <- assistants, do: {a, Octoroom.Agent.conversation(room, a.id)}

    turns =
      Enum.find_value(saved, [], fn {_a, items} ->
        case Enum.filter(items, &(&1.role == "user")) do
          [] -> nil
          turns -> turns
        end
      end)

    replies =
      for {a, items} <- saved, %{role: "assistant"} = item <- items do
        %{
          id: "reply-#{a.id}-#{item.message_id}",
          kind: :reply,
          agent: a.id,
          name: a.name,
          text: item.text,
          status: item.status,
          at: clock(item.at),
          at_ms: item.at
        }
      end

    turns =
      turns
      |> Enum.with_index(1)
      |> Enum.map(fn {item, n} ->
        %{
          id: "turn-#{n}",
          kind: :turn,
          speaker: item[:speaker],
          text: item.text,
          at: clock(item.at),
          at_ms: item.at,
          verdicts: []
        }
      end)

    entries = Enum.sort_by(turns ++ replies, & &1.at_ms)

    socket
    |> assign(
      turns: length(turns),
      last_turns: %{},
      early: %{},
      reply_times: Map.new(replies, &{&1.id, &1.at})
    )
    |> stream(:transcript, entries, reset: true)
  end

  # -- What the room server tells us

  @impl true
  def handle_info({:octoroom, _room, {:worker_event, id, {:agent, event}}}, socket),
    do: {:noreply, assistant_event(socket, id, event)}

  # An assistant says what it's doing (its `presence:`).
  def handle_info({:octoroom, _room, {:worker, :updated, %{id: id, state: state}}}, socket),
    do: {:noreply, put_state(socket, id, presence_state(state))}

  # The same transcript the assistants send clients: this page builds its
  # own from their events, with decisions.
  def handle_info({:octoroom, _room, {:worker_notify, _id, _output, _type, _data}}, socket),
    do: {:noreply, socket}

  def handle_info({:octoroom, _room, _event}, socket), do: {:noreply, load(socket)}

  # From the assistant's set_theme tool. The root layout's theme script
  # handles "phx:set-theme", the event the header's theme toggle sends.
  def handle_info({:set_theme, theme}, socket),
    do: {:noreply, push_event(socket, "set-theme", %{theme: theme})}

  defp load(socket) do
    {participants, workers} =
      case Octoroom.Room.state(socket.assigns.room) do
        %{} = state -> {state.participants, state.workers}
        {:error, :no_room} -> {[], []}
      end

    running = MapSet.new(workers, & &1.id)

    assign(socket,
      participants: participants,
      present: Enum.filter(socket.assigns.assistants, &MapSet.member?(running, &1.id)),
      states: Map.new(workers, &{&1.id, presence_state(&1[:state])})
    )
  end

  # -- What the browser tells us

  @impl true
  def handle_event("join", %{"name" => name} = params, socket) do
    case String.trim(name) do
      "" ->
        {:noreply, assign(socket, form: to_form(params, errors: [name: {"can't be blank", []}]))}

      name ->
        {:noreply,
         socket
         |> assign(joining: true, form: to_form(params))
         |> push_event("join", %{name: name, camera: params["camera"] == "true"})}
    end
  end

  def handle_event("client", %{"state" => state} = params, socket) do
    me = if state == "joined", do: params["participant_id"]

    # The transcript is on the page only in the call, and a stream's entries
    # are sent once: fill it as the call appears.
    socket = if me && !socket.assigns.me, do: restore_transcript(socket), else: socket
    {:noreply, socket |> assign(me: me, joining: state == "joining") |> load()}
  end

  def handle_event("say_to", %{"to" => to}, socket), do: {:noreply, assign(socket, say_to: to)}

  # The Call hook couldn't send a typed message: the room said no.
  def handle_event("say_failed", %{"to" => id, "reason" => reason}, socket) do
    message =
      case reason do
        "rate_limited" -> "Slow down: too many messages to #{assistant_name(socket, id)}."
        "not_allowed" -> "#{assistant_name(socket, id)} can't hear you, so it won't read that."
        _ -> "Couldn't send that to #{assistant_name(socket, id)} (#{reason})."
      end

    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_event("saved_name", %{"name" => name}, socket) when is_binary(name),
    do: {:noreply, assign(socket, form: to_form(%{socket.assigns.form.params | "name" => name}))}

  # -- The assistants' events become the transcript

  # Each finished turn, with what the decision model made of it.
  #
  # Every assistant decides on every turn, but each runs its own
  # speech-to-text, which can split the same speech into turns differently.
  # So the transcript's turns, and their words, are the first assistant's
  # (the primary); the others' decisions join the latest of its turns from
  # that mic, or wait a few seconds for it. With the primary not in the
  # call, the others make their own entries.
  # Typed to one assistant: only that one decides, so it's an entry of its
  # own, whichever assistant it is.
  defp assistant_event(socket, id, {:decision, %{why: :typed} = d}) do
    verdict = %{
      id: id,
      name: assistant_name(socket, id),
      outcome: :reply,
      why: :typed,
      decision: nil
    }

    n = socket.assigns.turns + 1

    entry = %{
      id: "turn-#{n}",
      kind: :turn,
      typed: true,
      speaker: d.speaker,
      text: d.text,
      at: now(),
      at_ms: System.monotonic_time(:millisecond),
      verdicts: [verdict]
    }

    socket |> assign(turns: n) |> stream_insert(:transcript, entry)
  end

  defp assistant_event(socket, id, {:decision, d}) do
    verdict = %{
      id: id,
      name: assistant_name(socket, id),
      outcome: d.outcome,
      why: d.why,
      decision: d.decision,
      at_ms: System.monotonic_time(:millisecond)
    }

    if id == primary(socket) or primary_absent?(socket),
      do: add_turn(socket, d, verdict),
      else: join_turn(socket, d.source, verdict)
  end

  # Words as they're recognized, before the turn ends.
  # Only the primary's, while it's in the call, like the turns.
  defp assistant_event(socket, id, {:transcription, %{source: source} = t}) when source != nil do
    if id == primary(socket) or primary_absent?(socket),
      do: update(socket, :partials, &Map.put(&1, source, %{speaker: t.speaker, text: t.text})),
      else: socket
  end

  # A reply comes as "playing", then again with the same id as "completed",
  # or "interrupted" with only what people heard.
  defp assistant_event(socket, id, {:conversation, %{role: "assistant"} = item}) do
    dom_id = "reply-#{id}-#{item[:message_id] || System.unique_integer([:positive])}"
    at = socket.assigns.reply_times[dom_id] || now()

    socket
    |> assign(reply_times: Map.put(socket.assigns.reply_times, dom_id, at))
    |> stream_insert(:transcript, %{
      id: dom_id,
      kind: :reply,
      agent: id,
      name: assistant_name(socket, id),
      text: item.text,
      status: item.status,
      at: at
    })
  end

  defp assistant_event(socket, id, {:waiting, nil}),
    do: update(socket, :waiting, &Map.delete(&1, id))

  defp assistant_event(socket, id, {:waiting, %{speaker: speaker}}),
    do: update(socket, :waiting, &Map.put(&1, id, speaker))

  defp assistant_event(socket, _id, _event), do: socket

  @join_window_ms 6_000

  defp add_turn(socket, d, verdict) do
    {early, rest} = Map.pop(socket.assigns.early, d.source, [])
    early = Enum.filter(early, &(verdict.at_ms - &1.at_ms <= @join_window_ms))
    n = socket.assigns.turns + 1

    entry = %{
      id: "turn-#{n}",
      kind: :turn,
      speaker: d.speaker,
      text: d.text,
      at: now(),
      at_ms: verdict.at_ms,
      verdicts: Enum.reduce(early, [verdict], &put_verdict(&2, &1))
    }

    socket
    |> assign(
      turns: n,
      early: rest,
      last_turns: Map.put(socket.assigns.last_turns, d.source, entry)
    )
    |> update(:partials, &Map.delete(&1, d.source))
    |> stream_insert(:transcript, entry)
  end

  defp join_turn(socket, source, verdict) do
    case socket.assigns.last_turns[source] do
      %{at_ms: at} = entry when verdict.at_ms - at <= @join_window_ms ->
        entry = %{entry | verdicts: put_verdict(entry.verdicts, verdict)}

        socket
        |> assign(last_turns: Map.put(socket.assigns.last_turns, source, entry))
        |> stream_insert(:transcript, entry)

      _ ->
        update(socket, :early, &Map.update(&1, source, [verdict], fn vs -> vs ++ [verdict] end))
    end
  end

  # One row per assistant. If its speech-to-text split the turn in two, the
  # more active decision stays: replied over waited over listened.
  defp put_verdict(verdicts, verdict) do
    case Enum.find_index(verdicts, &(&1.id == verdict.id)) do
      nil ->
        verdicts ++ [verdict]

      i ->
        List.update_at(verdicts, i, fn old ->
          if rank(verdict.outcome) >= rank(old.outcome), do: verdict, else: old
        end)
    end
  end

  defp rank(:reply), do: 2
  defp rank(:wait), do: 1
  defp rank(_listen), do: 0

  defp primary(socket), do: hd(socket.assigns.assistants).id

  # Other assistants are in the call without the primary.
  defp primary_absent?(%{assigns: %{present: present}} = socket),
    do: present != [] and not Enum.any?(present, &(&1.id == primary(socket)))

  defp put_state(socket, id, state), do: update(socket, :states, &Map.put(&1, id, state))

  defp presence_state("thinking"), do: :thinking
  defp presence_state("speaking"), do: :speaking
  defp presence_state("waiting"), do: :waiting
  defp presence_state(_listening_or_unknown), do: :listening

  defp assistant_name(socket, id) do
    case Enum.find(socket.assigns.assistants, &(&1.id == id)) do
      %{name: name} -> name
      nil -> id
    end
  end

  defp now, do: NaiveDateTime.local_now() |> Calendar.strftime("%H:%M")

  # A saved item's time (unix ms) on the local clock, like `now/0`.
  defp clock(at_ms) do
    offset =
      round(NaiveDateTime.diff(NaiveDateTime.local_now(), NaiveDateTime.utc_now()) / 60)

    at_ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_naive()
    |> NaiveDateTime.add(offset, :minute)
    |> Calendar.strftime("%H:%M")
  end

  # -- Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} fluid>
      <div
        id="call"
        phx-hook="Call"
        data-room={@room}
        class="h-full bg-base-300 text-base-content"
      >
        <.lobby
          :if={!@me}
          form={@form}
          joining={@joining}
          participants={@participants}
          assistants={@assistants}
        />
        <.call
          :if={@me}
          me={@me}
          room={@room}
          participants={@participants}
          assistants={@present}
          names={Map.new(@assistants, &{&1.id, &1.name})}
          states={@states}
          say_to={@say_to}
          waiting={@waiting}
          partials={@partials}
          transcript={@streams.transcript}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :form, :map, required: true
  attr :joining, :boolean, required: true
  attr :participants, :list, required: true
  attr :assistants, :list, required: true

  defp lobby(assigns) do
    ~H"""
    <div class="flex h-full items-center justify-center p-6">
      <div class="card w-full max-w-md bg-base-100 shadow-xl">
        <div class="card-body gap-4">
          <.header>
            Ready to join?
            <:subtitle>{who_is_here(@participants)}</:subtitle>
          </.header>
          <div
            id="lobby-preview"
            phx-hook="LobbyPreview"
            phx-update="ignore"
            class="relative aspect-video overflow-hidden rounded-xl bg-base-200"
          >
            <video
              data-preview-video
              class="hidden size-full -scale-x-100 object-cover"
              autoplay
              playsinline
              muted
            >
            </video>
            <div
              data-preview-placeholder
              class="flex size-full flex-col items-center justify-center gap-2 text-sm opacity-60"
            >
              <.icon name="hero-video-camera" class="size-8" />
              <span data-preview-status>Preparing camera and mic…</span>
            </div>
          </div>
          <.form for={@form} id="join-form" phx-submit="join">
            <.input field={@form[:name]} label="Your name" placeholder="Ada" autocomplete="off" />
            <.input field={@form[:camera]} type="checkbox" label="Join with camera" />
            <.button variant="primary" class="btn btn-primary w-full mt-2" disabled={@joining}>
              <span :if={@joining} class="loading loading-spinner loading-sm"></span>
              {if @joining, do: "Joining…", else: "Join now"}
            </.button>
          </.form>
          <p class="flex items-center gap-2 text-sm opacity-70">
            <.icon name="hero-sparkles" class="size-4 text-primary" />
            {@assistants |> Enum.map(& &1.name) |> Enum.join(" and ")} join the call with you.
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp who_is_here([]), do: "Nobody else is here yet."

  defp who_is_here(participants) do
    names = Enum.map(participants, & &1.meta.name)
    "#{Enum.join(names, ", ")} and the assistants are in this call."
  end

  defp call(assigns) do
    screens = for p <- assigns.participants, Map.has_key?(p.tracks, "screen"), do: p

    tile_count =
      length(assigns.participants) + length(screens) + length(assigns.assistants)

    assigns = assign(assigns, screens: screens, cols: cols(tile_count))
    me = Enum.find(assigns.participants, &(&1.id == assigns.me))
    assigns = assign(assigns, my_tracks: (me && me.tracks) || %{})

    ~H"""
    <div class="flex h-full">
      <div class="flex min-w-0 flex-1 flex-col">
        <div class="flex min-h-0 flex-1 overflow-y-auto p-4">
          <div class={["m-auto grid w-full max-w-6xl gap-3", @cols]}>
            <.screen_tile :for={p <- @screens} participant={p} me={@me} />
            <.person_tile :for={p <- @participants} participant={p} me={@me} />
            <.assistant_tile
              :for={a <- @assistants}
              assistant={a}
              state={Map.get(@states, a.id, :listening)}
            />
          </div>
        </div>

        <.control_bar room={@room} tracks={@my_tracks} count={length(@participants)} />
      </div>

      <.transcript_panel
        transcript={@transcript}
        partials={@partials}
        waiting={@waiting}
        names={@names}
        assistants={@assistants}
        say_to={@say_to}
      />
    </div>
    """
  end

  defp cols(n) when n <= 1, do: "grid-cols-1 max-w-3xl"
  defp cols(n) when n <= 4, do: "grid-cols-1 sm:grid-cols-2"
  defp cols(n) when n <= 9, do: "grid-cols-2 lg:grid-cols-3"
  defp cols(_n), do: "grid-cols-2 lg:grid-cols-4"

  attr :participant, :map, required: true
  attr :me, :string, required: true

  defp person_tile(assigns) do
    p = assigns.participant
    camera = p.tracks["camera"]

    assigns =
      assign(assigns,
        id: p.id,
        name: p.meta.name,
        you?: p.id == assigns.me,
        video?: camera != nil and not camera.muted,
        mic_muted?: get_in(p.tracks, ["mic", :muted]) == true
      )

    ~H"""
    <div id={"tile-#{@id}"} class="relative aspect-video overflow-hidden rounded-xl bg-base-200">
      <video
        :if={@video?}
        id={"video-#{@id}-camera"}
        phx-hook="Video"
        phx-update="ignore"
        data-participant={@id}
        data-source="camera"
        data-local={to_string(@you?)}
        class={["size-full object-cover", @you? && "-scale-x-100"]}
        autoplay
        playsinline
        muted
      >
      </video>
      <div :if={!@video?} class="flex size-full items-center justify-center">
        <div class={["avatar avatar-placeholder"]}>
          <div class={["w-20 rounded-full text-3xl", avatar_color(@name)]}>
            <span>{String.first(@name) |> String.upcase()}</span>
          </div>
        </div>
      </div>
      <.speaking_ring id={@id} />
      <div class="absolute bottom-2 left-2 flex items-center gap-1 rounded-md bg-black/50 px-2 py-0.5 text-sm text-white">
        <.icon :if={@mic_muted?} name="hero-microphone-slash" class="size-4 text-error" />
        {@name}{if @you?, do: " (you)"}
      </div>
    </div>
    """
  end

  attr :participant, :map, required: true
  attr :me, :string, required: true

  defp screen_tile(assigns) do
    assigns =
      assign(assigns, id: assigns.participant.id, you?: assigns.participant.id == assigns.me)

    ~H"""
    <div
      id={"screen-#{@id}"}
      class="relative col-span-full aspect-video overflow-hidden rounded-xl bg-black"
    >
      <video
        id={"video-#{@id}-screen"}
        phx-hook="Video"
        phx-update="ignore"
        data-participant={@id}
        data-source="screen"
        data-local={to_string(@you?)}
        class="size-full object-contain"
        autoplay
        playsinline
        muted
      >
      </video>
      <div class="absolute bottom-2 left-2 flex items-center gap-1 rounded-md bg-black/50 px-2 py-0.5 text-sm text-white">
        <.icon name="hero-computer-desktop" class="size-4" />
        {if @you?, do: "You are presenting", else: "#{@participant.meta.name} is presenting"}
      </div>
    </div>
    """
  end

  attr :assistant, :map, required: true
  attr :state, :atom, required: true

  defp assistant_tile(assigns) do
    ~H"""
    <div
      id={"tile-#{@assistant.id}"}
      class="relative aspect-video overflow-hidden rounded-xl bg-base-200"
    >
      <div class="flex size-full flex-col items-center justify-center gap-3">
        <div class="avatar avatar-placeholder">
          <div class={[
            "w-20 rounded-full bg-gradient-to-br text-primary-content",
            assistant_gradient(@assistant.id),
            @state == :thinking && "animate-pulse"
          ]}>
            <.icon name={assistant_icon(@assistant.id)} class="size-10" />
          </div>
        </div>
        <span class={["badge badge-sm", state_badge(@state)]}>{state_label(@state)}</span>
      </div>
      <.speaking_ring id={@assistant.id} />
      <div class="absolute bottom-2 left-2 rounded-md bg-black/50 px-2 py-0.5 text-sm text-white">
        {@assistant.name}
      </div>
    </div>
    """
  end

  defp assistant_icon("atlas"), do: "hero-globe-americas"
  defp assistant_icon(_id), do: "hero-sparkles"

  defp assistant_gradient("atlas"), do: "from-accent to-info"
  defp assistant_gradient(_id), do: "from-primary to-secondary"

  defp state_label(:listening), do: "Listening"
  defp state_label(:thinking), do: "Thinking…"
  defp state_label(:waiting), do: "Waiting for others to answer"
  defp state_label(:speaking), do: "Speaking"

  defp state_badge(:listening), do: "badge-ghost"
  defp state_badge(:thinking), do: "badge-info"
  defp state_badge(:waiting), do: "badge-warning"
  defp state_badge(:speaking), do: "badge-primary"

  # Lit by the Call hook from audio levels. Ignored by LiveView, so a
  # re-render doesn't put it out.
  attr :id, :string, required: true

  defp speaking_ring(assigns) do
    ~H"""
    <div id={"ring-#{@id}"} phx-update="ignore" class="contents">
      <div
        data-level={@id}
        class="pointer-events-none absolute inset-0 rounded-xl opacity-0 ring-4 ring-inset ring-primary transition-opacity duration-150"
      >
      </div>
    </div>
    """
  end

  @avatar_colors ~w(bg-primary bg-secondary bg-accent bg-info bg-success bg-warning)

  defp avatar_color(name),
    do: Enum.at(@avatar_colors, :erlang.phash2(name, length(@avatar_colors))) <> " text-base-100"

  attr :room, :string, required: true
  attr :tracks, :map, required: true
  attr :count, :integer, required: true

  defp control_bar(assigns) do
    assigns =
      assign(assigns,
        mic_muted?: get_in(assigns.tracks, ["mic", :muted]) == true,
        camera?: Map.has_key?(assigns.tracks, "camera"),
        screen?: Map.has_key?(assigns.tracks, "screen")
      )

    ~H"""
    <div class="flex items-center gap-2 px-4 pb-4 sm:px-6">
      <div class="hidden flex-1 truncate text-sm opacity-80 sm:block">
        {@room} · {@count} {if @count == 1, do: "person", else: "people"}
      </div>
      <div class="flex flex-1 justify-center gap-2 sm:flex-none sm:gap-3">
        <.button
          id="toggle-mic"
          class={"btn btn-circle sm:btn-lg #{if @mic_muted?, do: "btn-error", else: "btn-neutral"}"}
          phx-click={JS.dispatch("meet:mic")}
          title={if @mic_muted?, do: "Turn on microphone", else: "Turn off microphone"}
        >
          <.icon
            name={if @mic_muted?, do: "hero-microphone-slash", else: "hero-microphone"}
            class="size-6"
          />
        </.button>
        <.button
          id="toggle-camera"
          class={"btn btn-circle sm:btn-lg #{if @camera?, do: "btn-neutral", else: "btn-error"}"}
          phx-click={JS.dispatch("meet:camera")}
          title={if @camera?, do: "Turn off camera", else: "Turn on camera"}
        >
          <.icon
            name={if @camera?, do: "hero-video-camera", else: "hero-video-camera-slash"}
            class="size-6"
          />
        </.button>
        <.button
          id="toggle-screen"
          class={"btn btn-circle sm:btn-lg #{if @screen?, do: "btn-primary", else: "btn-neutral"}"}
          phx-click={JS.dispatch("meet:screen")}
          title={if @screen?, do: "Stop presenting", else: "Present now"}
        >
          <.icon name="hero-computer-desktop" class="size-6" />
        </.button>
        <.button
          id="leave"
          class="btn btn-error rounded-full px-5 sm:btn-lg sm:px-6"
          phx-click={JS.dispatch("meet:leave")}
          title="Leave call"
        >
          <.icon name="hero-phone-x-mark" class="size-6" />
        </.button>
      </div>
      <div class="flex justify-end sm:flex-1">
        <.button
          id="toggle-transcript"
          class="btn btn-ghost btn-circle sm:btn-lg"
          phx-click={JS.toggle(to: "#transcript-panel", display: "flex")}
          title="Transcript"
        >
          <.icon name="hero-chat-bubble-bottom-center-text" class="size-6" />
        </.button>
      </div>
    </div>
    """
  end

  attr :transcript, :any, required: true
  attr :partials, :map, required: true
  attr :waiting, :map, required: true
  attr :names, :map, required: true, doc: "assistant id => name"
  attr :assistants, :list, required: true, doc: "the assistants in the call"
  attr :say_to, :string, default: nil

  defp transcript_panel(assigns) do
    ~H"""
    <aside
      id="transcript-panel"
      class="m-3 hidden w-96 shrink-0 flex-col rounded-xl bg-base-100 shadow-xl lg:ml-0 lg:flex max-lg:fixed max-lg:inset-x-0 max-lg:top-16 max-lg:bottom-20 max-lg:z-20 max-lg:mx-auto max-lg:w-auto max-lg:max-w-md"
    >
      <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
        <div>
          <h2 class="font-semibold">Transcript</h2>
          <p class="text-xs opacity-60">Each turn tagged with each assistant's decision</p>
        </div>
        <.button
          class="btn btn-ghost btn-sm btn-circle"
          phx-click={JS.hide(to: "#transcript-panel")}
          title="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </.button>
      </div>

      <div id="transcript-scroll" phx-hook=".ScrollToBottom" class="min-h-0 flex-1 overflow-y-auto">
        <div id="transcript" phx-update="stream" class="divide-y divide-base-200">
          <p id="transcript-empty" class="hidden p-4 text-sm opacity-60 only:block">
            Say something. Ask the room “what's the capital of Peru?”, or “Assistant, what time is it?”
          </p>
          <.entry :for={{dom_id, entry} <- @transcript} id={dom_id} entry={entry} />
        </div>
        <div :for={{source, p} <- @partials} id={"partial-#{source}"} class="px-4 py-3 opacity-60">
          <div class="text-sm font-semibold">{p.speaker}</div>
          <p class="text-sm italic">{p.text}</p>
        </div>
      </div>

      <div
        :for={{id, speaker} <- @waiting}
        id={"waiting-#{id}"}
        class="border-t border-base-300 px-4 py-2 text-sm"
      >
        <span class="loading loading-dots loading-xs align-middle"></span>
        {Map.get(@names, id, id)} is waiting to see if anyone answers {speaker}…
      </div>

      <form
        :if={@assistants != []}
        id="say-form"
        class="flex gap-2 border-t border-base-300 p-3"
        autocomplete="off"
      >
        <select
          name="to"
          phx-change="say_to"
          class="select select-sm w-28 shrink-0"
          aria-label="To"
        >
          <option :for={a <- @assistants} value={a.id} selected={a.id == @say_to}>{a.name}</option>
        </select>
        <input
          name="text"
          type="text"
          maxlength="1000"
          placeholder="Type to an assistant…"
          class="input input-sm min-w-0 flex-1"
          aria-label="Message"
        />
        <button class="btn btn-primary btn-sm btn-square" title="Send">
          <.icon name="hero-paper-airplane" class="size-4" />
        </button>
      </form>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ScrollToBottom">
        export default {
          mounted() {
            this.observer = new MutationObserver(() => (this.el.scrollTop = this.el.scrollHeight))
            this.observer.observe(this.el, {childList: true, subtree: true, characterData: true})
          },
          destroyed() { this.observer.disconnect() }
        }
      </script>
    </aside>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true

  defp entry(%{entry: %{kind: :turn}} = assigns) do
    ~H"""
    <div id={@id} class="px-4 py-3">
      <div class="flex items-baseline gap-2">
        <span class="text-sm font-semibold">{@entry.speaker}</span>
        <span class="text-xs opacity-50">{@entry.at}</span>
        <span :if={@entry[:typed]} class="badge badge-xs badge-ghost" title="Typed, not spoken">
          <.icon name="hero-chat-bubble-left-ellipsis" class="size-3" /> typed
        </span>
      </div>
      <p class="text-sm">{@entry.text || "…"}</p>
      <div
        :for={v <- @entry.verdicts}
        id={"#{@id}-#{v.id}"}
        class="mt-1.5 flex flex-wrap items-center gap-1"
      >
        <span class="w-16 text-xs font-semibold opacity-70">{v.name}</span>
        <span class={["badge badge-sm", outcome_badge(v.outcome)]}>{outcome_label(v.outcome)}</span>
        <span class="badge badge-sm badge-ghost">{why(v.why)}</span>
        <span :for={tag <- answer_tags(v.decision)} class="badge badge-sm badge-outline">
          {tag}
        </span>
        <span :if={v.decision} class="badge badge-sm badge-outline opacity-60">
          {v.decision.latency_ms} ms
        </span>
      </div>
    </div>
    """
  end

  defp entry(%{entry: %{kind: :reply}} = assigns) do
    ~H"""
    <div id={@id} class="bg-primary/10 px-4 py-3">
      <div class="flex items-baseline gap-2">
        <span class="flex items-center gap-1 text-sm font-semibold text-primary">
          <.icon name={assistant_icon(@entry.agent)} class="size-4" /> {@entry.name}
        </span>
        <span class="text-xs opacity-50">{@entry.at}</span>
      </div>
      <p class="text-sm">{@entry.text}</p>
      <div :if={@entry.status != "completed"} class="mt-1.5 flex gap-1">
        <span :if={@entry.status == "playing"} class="badge badge-sm badge-primary">speaking</span>
        <span :if={@entry.status == "interrupted"} class="badge badge-sm badge-warning">
          interrupted
        </span>
      </div>
    </div>
    """
  end

  defp outcome_label(:reply), do: "replied"
  defp outcome_label(:wait), do: "waited"
  defp outcome_label(:listen), do: "listened"

  defp outcome_badge(:reply), do: "badge-success"
  defp outcome_badge(:wait), do: "badge-warning"
  defp outcome_badge(:listen), do: "badge-neutral"

  defp why(:name), do: "said its name"
  defp why(:follow_up), do: "follow-up"
  defp why(:addressed), do: "talking to it"
  defp why(:maybe_addressed), do: "maybe talking to it"
  defp why(:open_question), do: "open question"
  defp why(:not_addressed), do: "not for it"
  defp why(:named_other), do: "named someone else"
  defp why(:not_about_capitals), do: "not about capitals"
  defp why(:decided), do: "its own rule"
  defp why(:typed), do: "typed to it"
  defp why(other), do: other |> to_string() |> String.replace("_", " ")

  # The decision model's answers, as tags: every question it was asked,
  # the app's own included ("capital 92%").
  defp answer_tags(nil), do: []

  defp answer_tags(%{answers: answers}) when is_map(answers) do
    for {question, answer} <- Enum.sort(answers) do
      case answer do
        %{"choice" => choice, "confidence" => p} -> "to #{choice} #{pct(p)}"
        %{"probability" => p} -> "#{question_label(question)} #{pct(p)}"
        _ -> question
      end
    end
  end

  defp answer_tags(d),
    do: ["to #{d.addressee} #{pct(d.confidence)}", "answerable #{pct(d.answerable)}"]

  defp question_label("answerable_" <> id), do: "#{id} could answer"
  defp question_label(question), do: question

  defp pct(nil), do: "—"
  defp pct(p), do: "#{round(p * 100)}%"
end
