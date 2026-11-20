defmodule Octoroom.Agent.WorkerTest do
  # An agent in a real room server, over Octoroom's fake Cloudflare and fake
  # peer media, with fake STT, LLM and TTS.
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.{Frames, Processors}
  alias Octoroom.Room.Server
  alias Octoroom.Test.{Client, FakeCloudflare, FakePeerMedia}

  # 20 ms of room PCM.
  @frame :binary.copy(<<1, 0>>, 1_920)

  # Stands in for `Processors.STT`: remembers the source of the audio it
  # hears, and turns `{:fake_stt, source, ...}` messages for that source into
  # what the real stage pushes.
  # Stands where the decision stage would: the fake STT's turns already
  # carry their decisions, so no model is asked.
  defmodule NoDecisions do
    use Octoroom.Agent.Processor
  end

  defmodule FakeSTT do
    use Octoroom.Agent.Processor

    @impl true
    def init(opts, _ctx), do: {:ok, %{source: nil, test: Keyword.fetch!(opts, :test)}}

    @impl true
    def handle_frame(%Frames.InputAudio{} = frame, :downstream, state) do
      if state.source == nil, do: send(state.test, {:heard, frame.source, frame.sample_rate})
      {[{:push, frame, :downstream}], %{state | source: frame.source}}
    end

    def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

    @impl true
    def handle_info({:fake_stt, source, event}, %{source: source} = state),
      do: {[{:push, frame(event, source), :downstream}], state}

    def handle_info(_message, state), do: {[], state}

    defp frame(:speech_started, source), do: %Frames.VADUserStartedSpeaking{source: source}
    defp frame(:speech_stopped, source), do: %Frames.VADUserStoppedSpeaking{source: source}
    defp frame({:final, text}, source), do: %Frames.Transcription{text: text, source: source}

    defp frame({:audio, ms}, source),
      do: %Frames.UserAudio{audio: :binary.copy(<<0, 0>>, 16 * ms), source: source}

    defp frame({:final, text, decision}, source),
      do: %Frames.Transcription{text: text, source: source, decision: decision}
  end

  # An `Octoroom.Agent` module whose `ctx.args` are the worker args the
  # other tests use, fakes included.
  defmodule TestAgent do
    use Octoroom.Agent

    @impl true
    def instructions(ctx), do: ctx.args.instructions

    @impl true
    def tools(_ctx) do
      [
        %Octoroom.Agent.Tool{
          name: "whoami",
          description: "Who is asking.",
          parameters: %{type: "object", properties: %{}},
          handler: {__MODULE__, :whoami}
        }
      ]
    end

    @impl true
    def pipeline(ctx), do: {ctx.args.front_end, ctx.args.back_end}

    def whoami(call, ctx),
      do: %{id: call.id, name: call.name, response: %{speaker: ctx.speaker.meta.name}}
  end

  # Answers only questions about capitals: its own question, read by its
  # own `decide/2`.
  defmodule CapitalsAgent do
    use Octoroom.Agent

    @impl true
    def pipeline(ctx), do: {ctx.args.front_end, ctx.args.back_end}

    @impl true
    def decide(turn, ctx) do
      case get_in(turn.decision, [:answers, "capital", "probability"]) do
        p when p >= 0.6 -> Octoroom.Agent.decide(turn, ctx)
        _ -> {:listen, :not_about_capitals}
      end
    end
  end

  defmodule AgentRoom do
    use Octoroom.Room

    @impl true
    def join(_params, _socket), do: {:ok, %{}}

    # One agent hearing everyone; the participant who brought args starts it.
    @impl true
    def workers(%{participants: [_ | _]} = room) do
      case Enum.find(room.participants, &Map.has_key?(&1.meta, :args)) do
        nil ->
          []

        %{meta: %{agent: opts}} = p ->
          hears = Enum.map(room.participants, &mic/1)
          {module, opts} = Keyword.pop(opts, :module, TestAgent)

          [
            Octoroom.Agent.agent(
              "assistant",
              module,
              [hears: hears, args: p.meta.args] ++ opts
            )
          ]

        p ->
          [
            worker("assistant", Octoroom.Agent.Worker,
              inputs: Enum.map(room.participants, &mic/1),
              outputs: ["assistant"],
              args: p.meta.args
            )
          ]
      end
    end

    def workers(_room), do: []

    @impl true
    def subscriptions(_listener, _room), do: [track("assistant")]
  end

  # Named, as `default/1` wants, and then replaced by fakes.
  @providers [
    stt: "soniox:stt-rt-v6",
    llm: [provider: :google, model: "gemini-3.5-flash"],
    tts: "inworld:inworld-tts-2"
  ]

  setup do
    {:ok, fake} = FakeCloudflare.start_link(self())

    %{
      fake: fake,
      room_id: "agent-room-#{System.unique_integer([:positive])}",
      opts: [
        cloudflare: FakeCloudflare.config(fake),
        signal_timeout: 1_000,
        peer_media: FakePeerMedia
      ]
    }
  end

  # `reply_ms` of 24 kHz audio per sentence the LLM says.
  defp args(test, reply_ms, extra \\ %{}) do
    {llm, extra} =
      Map.pop_lazy(extra, :llm, fn ->
        fn opts, emit ->
          send(test, {:llm, Enum.map(opts[:input], & &1.content)})
          emit.({:text_delta, "Hello there."})
          {:ok, %{text: "Hello there.", function_calls: [], continuation: []}}
        end
      end)

    tts = fn text, on_audio ->
      send(test, :tts)
      send(test, {:tts, text})
      on_audio.(:binary.copy(<<0, 0>>, div(24_000 * reply_ms, 1_000)))
      :ok
    end

    {front, back} = default([vad: false] ++ @providers)

    # Half-cascaded back ends transcribe each audio turn in the background.
    {transcribe, extra} = Map.pop(extra, :transcribe)

    back =
      if transcribe,
        do:
          insert_before(
            back,
            :context,
            processor(:transcriber, Processors.Transcriber, transcribe: transcribe)
          ),
        else: back

    Map.merge(
      %{
        name: "Assistant",
        instructions: "Be brief.",
        front_end:
          front
          |> replace(:stt, processor(:stt, FakeSTT, test: test))
          |> processor(:decisions, NoDecisions),
        back_end:
          back
          |> replace(:llm, processor(:llm, Processors.LLM, request: llm))
          |> replace(:tts, processor(:tts, Processors.TTS, synthesize: tts))
      },
      extra
    )
  end

  # Alice joins and publishes her mic. The agent pulls it, and once it has
  # heard her, it can talk.
  defp start(ctx, reply_ms \\ 200, extra \\ %{}) do
    Octoroom.subscribe(ctx.room_id, scope: :room)
    {agent, extra} = Map.pop(extra, :agent)
    meta = %{name: "Alice", args: args(self(), reply_ms, extra)}
    meta = if agent, do: Map.put(meta, :agent, agent), else: meta
    alice = join(ctx, "alice", meta)
    cf = agent_track(alice.mic)
    alice = hear(ctx, alice)
    %{alice: alice, mic: alice.mic, cf_track: cf}
  end

  defp join(ctx, name, meta) do
    client = Client.join(name, AgentRoom, ctx.room_id, meta, ctx.opts)
    Server.publish(client.server, client.id, "offer:#{name}", %{"mic" => "0"}, :pub)
    assert_receive {:client, ^name, {:octoroom_signal, :reply, :pub, {:ok, %{sdp: sdp}}}}
    "answer:" <> session = sdp
    mic = "#{client.id}/mic"
    FakeCloudflare.mark_live(ctx.fake, session, mic)
    Server.connected(client.server, client.id)
    Map.merge(client, %{session: session, mic: mic})
  end

  # Waits until the agent pulls `client`'s mic and its front end hears it.
  defp hear(ctx, client) do
    mic = client.mic

    wait_until(fn ->
      match?([%{connected: connected}] when is_list(connected), workers(ctx)) and
        mic in hd(workers(ctx)).connected
    end)

    FakeCloudflare.egress(ctx.fake, client.session, mic, @frame)
    assert_receive {:heard, ^mic, 16_000}
    client
  end

  defp workers(ctx), do: Octoroom.Room.state(ctx.room_id).workers

  # The agent's output, pushed from its own session (Alice's mic is the
  # other push).
  defp agent_track(mic) do
    assert_receive {:cloudflare, :push_tracks, [_session, _offer, [%{track_name: name}]]}
    if name == mic, do: agent_track(mic), else: name
  end

  defp say(ctx, client, event),
    do: :ok = Octoroom.Worker.send(ctx.room_id, "assistant", {:fake_stt, client.mic, event})

  test "hears a participant, replies on its track, and reports the turn", ctx do
    %{cf_track: cf, alice: alice} = start(ctx)

    say(ctx, alice, {:final, "Hi!"})

    assert_receive {:octoroom, _,
                    {:worker_event, "assistant",
                     {:agent, {:conversation, %{role: "user", text: "Hi!", speaker: "Alice"}}}}}

    assert_receive {:octoroom, _,
                    {:worker_event, "assistant",
                     {:agent, {:latency, %{transcript: t, llm: l, audio: a}}}}}

    assert t >= 0 and l >= t and a >= l

    assert_receive {:octoroom, _,
                    {:worker_event, "assistant",
                     {:agent,
                      {:conversation,
                       %{role: "assistant", text: "Hello there.", status: "completed"}}}}},
                   # Once its audio has played.
                   1_000

    # The reply goes out on the agent's track as 20 ms room frames.
    assert_receive {:ingest, ^cf, frame}, 1_000
    assert byte_size(frame) == 3_840
  end

  test "a restarted agent carries on the conversation, and apps can read it", ctx do
    %{alice: alice} = start(ctx, 50, %{initial_text: "Greet everyone."})
    # The greeting starts 100 ms after the agent does.
    assert_receive {:llm, ["Be brief.", "Greet everyone."]}, 1_000

    assert_receive {:octoroom, _,
                    {:worker_event, "assistant",
                     {:agent, {:conversation, %{role: "assistant", status: "completed"}}}}},
                   1_000

    say(ctx, alice, {:final, "My name is Alice."})
    assert_receive {:llm, [_, _, _, "[Alice] My name is Alice."]}

    assert_receive {:octoroom, _,
                    {:worker_event, "assistant",
                     {:agent, {:conversation, %{role: "assistant", status: "completed"}}}}},
                   1_000

    wait_until(fn -> length(Octoroom.Agent.conversation(ctx.room_id, "assistant")) == 3 end)

    assert [
             %{role: "assistant", text: "Hello there.", at: at},
             %{role: "user", text: "My name is Alice.", speaker: "Alice"},
             %{role: "assistant", text: "Hello there.", status: "completed"}
           ] = Octoroom.Agent.conversation(ctx.room_id, "assistant")

    assert is_integer(at)

    # It crashes; the room starts it again with what it saved.
    pid = Octoroom.Worker.whereis(ctx.room_id, "assistant")
    Process.exit(pid, :kill)
    wait_until(fn -> Octoroom.Worker.whereis(ctx.room_id, "assistant") not in [nil, pid] end)
    hear(ctx, alice)

    say(ctx, alice, {:final, "What's my name?"})

    # No second greeting: the first request after the restart is this turn,
    # with everything before it.
    assert_receive {:llm, request}, 2_000

    assert request == [
             "Be brief.",
             "Greet everyone.",
             "Hello there.",
             "[Alice] My name is Alice.",
             "Hello there.",
             "[Alice] What's my name?"
           ]

    # Saved just after the turn reaches the LLM.
    wait_until(fn -> length(Octoroom.Agent.conversation(ctx.room_id, "assistant")) == 4 end)
  end

  test "talking over the agent flushes what it hasn't played yet", ctx do
    %{cf_track: cf, alice: alice} = start(ctx, 5_000)

    say(ctx, alice, {:final, "Tell me a story."})
    assert_receive :tts
    assert_receive {:ingest, ^cf, _}, 1_000
    wait_until(fn -> Octoroom.Outlet.stats(ctx.room_id, "assistant").queued_ms > 3_000 end)

    say(ctx, alice, :speech_started)
    wait_until(fn -> Octoroom.Outlet.stats(ctx.room_id, "assistant").queued_ms == 0 end)
  end

  test "a reply cut off keeps only what was heard, and the LLM is told", ctx do
    sentence = "One two three four five six seven eight nine ten."

    test = self()

    llm = fn opts, emit ->
      send(test, {:llm, Enum.map(opts[:input], & &1.content)})
      emit.({:text_delta, sentence})
      {:ok, %{text: sentence, function_calls: [], continuation: []}}
    end

    # Alice's client never answers the room's offers; give it time to.
    ctx = %{ctx | opts: Keyword.put(ctx.opts, :signal_timeout, 10_000)}

    # The sentence is one chunk of 5 s of audio.
    %{cf_track: cf, alice: alice} = start(ctx, 5_000, %{llm: llm})

    say(ctx, alice, {:final, "Count to ten."})
    assert_receive {:llm, _}
    assert_receive {:ingest, ^cf, _}, 1_000

    # About 1.5 s plays, then Alice talks over it.
    Process.sleep(1_500)
    say(ctx, alice, :speech_started)

    assert_receive {:octoroom, _,
                    {:worker_event, "assistant",
                     {:agent,
                      {:conversation, %{role: "assistant", status: "interrupted", text: heard}}}}},
                   1_000

    # Two to four of the ten words, by how much of the audio played.
    words = String.split(heard)
    assert length(words) in 2..4
    assert String.starts_with?(sentence, heard)

    # The next request has what was heard, marked as cut off.
    say(ctx, alice, :speech_stopped)
    say(ctx, alice, {:final, "Keep going."})
    assert_receive {:llm, input}, 1_000
    assert (heard <> "… [interrupted]") in input
  end

  test "with several people it hears everyone and answers when addressed", ctx do
    %{alice: alice} = start(ctx)
    bob = join(ctx, "bob", %{name: "Bob"}) |> then(&hear(ctx, &1))

    # People talking to each other: into the conversation, no reply.
    say(ctx, alice, {:final, "Bob, did you send the deck?"})
    say(ctx, bob, {:final, "Yes, this morning."})

    assert_receive {:octoroom, _,
                    {:worker_event, "assistant",
                     {:agent, {:conversation, %{text: "Yes, this morning.", speaker: "Bob"}}}}}

    refute_receive {:llm, _}, 100

    # Saying its name starts a reply, with everyone's words, labelled.
    say(ctx, bob, {:final, "Assistant, when is the meeting?"})
    assert_receive {:llm, input}

    assert Enum.take(input, -3) == [
             "[Alice] Bob, did you send the deck?",
             "[Bob] Yes, this morning.",
             "[Bob] Assistant, when is the meeting?"
           ]

    assert_receive {:octoroom, _,
                    {:worker_event, "assistant",
                     {:agent, {:conversation, %{role: "assistant", status: "completed"}}}}},
                   1_000

    # Bob's follow-up window: 10 s from when the reply's 200 ms of audio ends.
    assert_receive {:octoroom, _,
                    {:worker_event, "assistant",
                     {:agent, {:follow_up, %{speaker: "Bob", source: source, ms: ms}}}}}

    assert source == bob.mic
    assert ms >= 10_000 and ms <= 10_200

    # Bob can follow up without the name; Alice can't.
    say(ctx, alice, {:final, "And where?"})
    refute_receive {:llm, _}, 100
    say(ctx, bob, {:final, "And where?"})
    assert_receive {:llm, _}
    assert_receive {:octoroom, _, {:worker_event, "assistant", {:agent, {:follow_up, nil}}}}
  end

  test "only the person it's answering can interrupt it", ctx do
    %{alice: alice} = start(ctx, 5_000)
    bob = join(ctx, "bob", %{name: "Bob"}) |> then(&hear(ctx, &1))

    say(ctx, bob, {:final, "Assistant, tell me a story."})
    assert_receive :tts
    wait_until(fn -> Octoroom.Outlet.stats(ctx.room_id, "assistant").queued_ms > 3_000 end)

    say(ctx, alice, :speech_started)
    Process.sleep(100)
    assert Octoroom.Outlet.stats(ctx.room_id, "assistant").queued_ms > 2_000

    say(ctx, bob, :speech_started)
    wait_until(fn -> Octoroom.Outlet.stats(ctx.room_id, "assistant").queued_ms == 0 end)
  end

  test "half-cascaded: the LLM hears a labelled audio turn, and a transcript follows", ctx do
    transcribe = fn _pcm, _rate -> {:ok, "What time is it?"} end
    %{alice: alice} = start(ctx, 200, %{transcribe: transcribe})

    say(ctx, alice, {:audio, 1_000})
    assert_receive {:llm, input}

    assert [%ReqLLM.Message.ContentPart{type: :text, text: "[Alice]"}, %{type: :file}] =
             List.last(input)

    # The background transcript becomes Alice's line in the conversation.
    assert_receive {:octoroom, _,
                    {:worker_event, "assistant",
                     {:agent,
                      {:conversation, %{role: "user", text: "What time is it?", speaker: "Alice"}}}}},
                   1_000
  end

  describe "the decision gate" do
    @decision_args %{gate: :decision, thresholds: %{wait_ms: 300}}

    defp decision(addressee, assistant, answerable),
      do: %{
        addressee: addressee,
        probabilities: %{"assistant" => assistant},
        answerable: answerable
      }

    defp event(kind) do
      assert_receive {:octoroom, _, {:worker_event, "assistant", {:agent, {^kind, value}}}},
                     1_000

      value
    end

    test "replies when the model hears it addressed, without its name", ctx do
      %{alice: alice} = start(ctx, 200, @decision_args)
      say(ctx, alice, {:final, "What time is it?", decision("assistant", 0.85, 0.9)})
      assert %{outcome: :reply, why: :addressed, speaker: "Alice"} = event(:decision)
      assert_receive {:llm, _}
    end

    test "an open question waits, then gets an answer if nobody else speaks", ctx do
      %{alice: alice} = start(ctx, 200, @decision_args)
      say(ctx, alice, {:final, "Does anyone know when it starts?", decision("group", 0.1, 0.9)})
      assert %{outcome: :wait, why: :open_question} = event(:decision)
      assert %{speaker: "Alice", ms: 300} = event(:waiting)
      refute_receive {:llm, _}, 150
      assert nil == event(:waiting)
      assert_receive {:llm, input}
      assert List.last(input) == "[Alice] Does anyone know when it starts?"
    end

    test "someone else answering ends the wait without a reply", ctx do
      %{alice: alice} = start(ctx, 200, @decision_args)
      bob = join(ctx, "bob", %{name: "Bob"}) |> then(&hear(ctx, &1))
      say(ctx, alice, {:final, "Does anyone know when it starts?", decision("group", 0.1, 0.9)})
      assert %{ms: 300} = event(:waiting)
      say(ctx, bob, :speech_started)
      assert nil == event(:waiting)
      refute_receive {:llm, _}, 500

      assert_receive {:octoroom, _,
                      {:worker_event, "assistant",
                       {:agent, {:conversation, %{text: "Does anyone know when it starts?"}}}}}
    end

    test "talk aimed at a person stays in the conversation, unanswered", ctx do
      %{alice: alice} = start(ctx, 200, @decision_args)
      say(ctx, alice, {:final, "Bob, can you share your screen?", decision("person", 0.05, 0.3)})
      assert %{outcome: :listen} = event(:decision)
      refute_receive {:llm, _}, 400
    end

    test "the person it's answering carries on without the name", ctx do
      %{alice: alice} = start(ctx, 5_000, @decision_args)
      say(ctx, alice, {:final, "Assistant."})
      assert %{outcome: :reply, why: :name} = event(:decision)
      say(ctx, alice, {:final, "What time is it?", decision("group", 0.4, 0.9)})
      assert %{outcome: :reply, why: :follow_up} = event(:decision)
    end

    test "in the follow-up window, talk aimed at someone else gets no reply", ctx do
      %{alice: alice} = start(ctx, 200, Map.put(@decision_args, :follow_up_ms, 10_000))
      say(ctx, alice, {:final, "What time is it?", decision("assistant", 0.85, 0.9)})
      assert %{outcome: :reply, why: :addressed} = event(:decision)
      assert_receive {:llm, _}

      assert_receive {:octoroom, _,
                      {:worker_event, "assistant", {:agent, {:follow_up, %{speaker: "Alice"}}}}},
                     2_000

      say(ctx, alice, {:final, "Bob, can you share your screen?", decision("person", 0.05, 0.3)})
      assert %{outcome: :listen, why: :not_addressed} = event(:decision)
      refute_receive {:llm, _}, 400

      say(ctx, alice, {:final, "And in Tokyo?", decision("nobody", 0.3, 0.8)})
      assert %{outcome: :reply, why: :follow_up} = event(:decision)
      assert_receive {:llm, _}
    end

    test "a follow-up with no decision still gets a reply", ctx do
      %{alice: alice} = start(ctx, 200, Map.put(@decision_args, :follow_up_ms, 10_000))
      say(ctx, alice, {:final, "Assistant, what time is it?"})
      assert %{outcome: :reply, why: :name} = event(:decision)
      assert_receive {:llm, _}

      assert_receive {:octoroom, _,
                      {:worker_event, "assistant", {:agent, {:follow_up, %{speaker: "Alice"}}}}},
                     2_000

      say(ctx, alice, {:final, "And in Tokyo?"})
      assert %{outcome: :reply, why: :follow_up} = event(:decision)
    end

    test "a module's decide/2 reads the answers to its own questions", ctx do
      %{alice: alice} =
        start(ctx, 200, %{
          agent: [module: CapitalsAgent, gate: :decision, thresholds: %{wait_ms: 300}]
        })

      not_capitals =
        put_in(decision("assistant", 0.9, 0.9)[:answers], %{"capital" => %{"probability" => 0.1}})

      say(ctx, alice, {:final, "What's the weather like?", not_capitals})
      assert %{outcome: :listen, why: :not_about_capitals} = event(:decision)
      refute_receive {:llm, _}, 300

      # Asked by name, it can still say no.
      say(ctx, alice, {:final, "Assistant, what's the weather like?", not_capitals})
      assert %{outcome: :listen, why: :not_about_capitals} = event(:decision)
      refute_receive {:llm, _}, 300

      capitals =
        put_in(decision("assistant", 0.9, 0.9)[:answers], %{"capital" => %{"probability" => 0.95}})

      say(ctx, alice, {:final, "What's the capital of Peru?", capitals})
      assert %{outcome: :reply, why: :addressed} = event(:decision)
      assert_receive {:llm, _}
    end

    test "with other agents, it answers what's for it and leaves the rest", ctx do
      roster = [%{id: "assistant", name: "Assistant"}, %{id: "atlas", name: "Atlas"}]
      %{alice: alice} = start(ctx, 200, Map.put(@decision_args, :roster, roster))

      for_atlas = %{addressee: "atlas", probabilities: %{"atlas" => 0.85, "assistant" => 0.1}}
      say(ctx, alice, {:final, "What's the capital of Peru?", for_atlas})
      assert %{outcome: :listen} = event(:decision)

      # An open question goes to whichever agent is likelier to answer it.
      open = fn mine, theirs ->
        %{
          addressee: "group",
          probabilities: %{"atlas" => 0.1, "assistant" => 0.1},
          answers: %{
            "answerable_assistant" => %{"probability" => mine},
            "answerable_atlas" => %{"probability" => theirs}
          }
        }
      end

      say(ctx, alice, {:final, "Anyone know the capital of Peru?", open.(0.75, 0.95)})
      assert %{outcome: :listen} = event(:decision)
      say(ctx, alice, {:final, "Anyone free on Friday?", open.(0.9, 0.2)})
      assert %{outcome: :wait, why: :open_question} = event(:decision)
    end

    test "naming another agent isn't a follow-up", ctx do
      roster = [%{id: "assistant", name: "Assistant"}, %{id: "atlas", name: "Atlas"}]
      args = @decision_args |> Map.put(:roster, roster) |> Map.put(:follow_up_ms, 10_000)
      %{alice: alice} = start(ctx, 200, args)
      say(ctx, alice, {:final, "Assistant, what time is it?"})
      assert %{outcome: :reply, why: :name} = event(:decision)
      assert_receive {:llm, _}

      assert_receive {:octoroom, _,
                      {:worker_event, "assistant", {:agent, {:follow_up, %{speaker: "Alice"}}}}},
                     2_000

      say(ctx, alice, {:final, "Atlas, and the capital of Peru?"})
      assert %{outcome: :listen, why: :named_other} = event(:decision)
    end

    test "with no decision (a failed or slow call) only the name counts", ctx do
      %{alice: alice} = start(ctx, 200, @decision_args)
      say(ctx, alice, {:final, "What time is it?"})
      assert %{outcome: :listen, decision: nil} = event(:decision)
      say(ctx, alice, {:final, "Assistant, what time is it?"})
      assert %{outcome: :reply, why: :name} = event(:decision)
      assert_receive {:llm, _}
    end
  end

  describe "an Octoroom.Agent module" do
    test "replies on its own track, and its tools know who asked", ctx do
      test = self()

      llm = fn opts, emit ->
        case Enum.find(opts[:input], &match?(%ReqLLM.Message{role: :tool}, &1)) do
          nil ->
            emit.({:tool_call_delta, %{}})
            call = %{id: "c1", name: "whoami", args: %{}}
            {:ok, %{text: "", function_calls: [call], continuation: []}}

          result ->
            send(test, {:tool_result, inspect(result.content)})
            emit.({:text_delta, "You're Alice."})
            {:ok, %{text: "You're Alice.", function_calls: [], continuation: []}}
        end
      end

      %{cf_track: cf, alice: alice} = start(ctx, 200, %{agent: [], llm: llm})

      say(ctx, alice, {:final, "Who am I?"})
      assert_receive {:tool_result, result}, 1_000
      assert result =~ "Alice"

      assert_receive {:octoroom, _,
                      {:worker_event, "assistant",
                       {:agent, {:conversation, %{role: "assistant", text: "You're Alice."}}}}},
                     1_000

      assert_receive {:ingest, ^cf, _}, 1_000
    end

    test "say/3 speaks word for word, into the conversation", ctx do
      %{cf_track: cf} = start(ctx, 200, %{agent: []})

      assert Octoroom.Agent.say(ctx.room_id, "assistant", "Recording has started.") == :ok
      assert_receive {:tts, "Recording has started."}
      refute_received {:llm, _}

      assert_receive {:octoroom, _,
                      {:worker_event, "assistant",
                       {:agent,
                        {:conversation,
                         %{role: "assistant", text: "Recording has started.", status: "completed"}}}}},
                     1_000

      assert_receive {:ingest, ^cf, _}, 1_000
    end

    test "say/3 cuts off what it was saying", ctx do
      %{alice: alice} = start(ctx, 5_000, %{agent: []})
      say(ctx, alice, {:final, "Tell me a story."})
      assert_receive {:tts, "Hello there."}
      wait_until(fn -> Octoroom.Outlet.stats(ctx.room_id, "assistant").queued_ms > 3_000 end)

      # The story is flushed: without that, 5 s more would queue behind it.
      Octoroom.Agent.say(ctx.room_id, "assistant", "Sorry, one moment.")
      assert_receive {:tts, "Sorry, one moment."}
      Process.sleep(50)
      assert Octoroom.Outlet.stats(ctx.room_id, "assistant").queued_ms <= 5_000
    end

    test "prompt/3 starts a reply to the app, not to anyone on the call", ctx do
      start(ctx, 200, %{agent: []})

      assert Octoroom.Agent.prompt(ctx.room_id, "assistant", "Summarize the call.") == :ok
      assert_receive {:llm, input}

      assert List.last(input) ==
               "[From the app, not said by anyone on the call] Summarize the call."

      assert_receive {:tts, "Hello there."}
    end

    test "interrupt/2 stops it", ctx do
      %{alice: alice} = start(ctx, 5_000, %{agent: []})
      say(ctx, alice, {:final, "Tell me a story."})
      wait_until(fn -> Octoroom.Outlet.stats(ctx.room_id, "assistant").queued_ms > 3_000 end)

      assert Octoroom.Agent.interrupt(ctx.room_id, "assistant") == :ok
      wait_until(fn -> Octoroom.Outlet.stats(ctx.room_id, "assistant").queued_ms == 0 end)
    end

    test "the app's messages report a missing agent" do
      assert Octoroom.Agent.say("no-room", "assistant", "Hi") == {:error, :no_worker}
      assert Octoroom.Agent.prompt("no-room", "assistant", "Hi") == {:error, :no_worker}
      assert Octoroom.Agent.interrupt("no-room", "assistant") == {:error, :no_worker}
    end
  end

  describe "UpdateStage from the back end" do
    # In a front end: tells the test about each update.
    defmodule UpdateSpy do
      use Octoroom.Agent.Processor

      @impl true
      def init(opts, _ctx), do: {:ok, Keyword.fetch!(opts, :test)}

      @impl true
      def handle_update(opts, test) do
        send(test, {:updated, opts})
        {[], test}
      end
    end

    # In the back end: "update <value>" sets `value` on the front ends' spy.
    defmodule Updater do
      use Octoroom.Agent.Processor

      @impl true
      def handle_frame(%Frames.Transcription{text: "update " <> value} = frame, :downstream, s) do
        update = %Frames.UpdateStage{stage: :spy, opts: [value: value]}
        {[{:push, frame, :downstream}, {:push, update, :upstream}], s}
      end

      def handle_frame(frame, direction, s), do: {[{:push, frame, direction}], s}
    end

    test "reaches every front end, and front ends that start later", ctx do
      base = args(self(), 200)

      extra = %{
        front_end: insert_after(base.front_end, :turns, processor(:spy, UpdateSpy, test: self())),
        back_end: insert_before(base.back_end, :context, processor(:updater, Updater))
      }

      %{alice: alice} = start(ctx, 200, extra)
      say(ctx, alice, {:final, "update calm"})
      assert_receive {:updated, [value: "calm"]}

      say(ctx, alice, {:final, "update brisk"})
      assert_receive {:updated, [value: "brisk"]}

      # Bob's front end starts with the latest value.
      _bob = join(ctx, "bob", %{name: "Bob"}) |> then(&hear(ctx, &1))
      assert_receive {:updated, [value: "brisk"]}
      refute_receive {:updated, _}, 100
    end
  end

  describe "agent/3" do
    import Octoroom.Room, only: [track: 1]

    test "is a worker spec with one output named after it" do
      spec =
        Octoroom.Agent.agent("assistant", TestAgent,
          hears: [track("a/mic"), "b/mic"],
          respond: :addressed,
          args: %{workspace: 1}
        )

      assert %{id: "assistant", module: Octoroom.Agent.Worker} = spec
      assert spec.inputs == ["a/mic", "b/mic"]
      assert spec.outputs == ["assistant"]

      assert spec.args == %{
               agent: TestAgent,
               args: %{workspace: 1},
               name: "assistant",
               respond: :addressed,
               voice: true
             }
    end

    test "voice: false gives it no track" do
      spec = Octoroom.Agent.agent("notes", TestAgent, hears: [], voice: false)
      assert spec.outputs == []
      assert spec.args.voice == false
    end

    test "refuses a missing hears: and unknown options" do
      assert_raise ArgumentError, ~r/hears: is required/, fn ->
        Octoroom.Agent.agent("a", TestAgent, [])
      end

      assert_raise ArgumentError, ~r/unknown options \[:interrupt\]/, fn ->
        Octoroom.Agent.agent("a", TestAgent, hears: [], interrupt: :anyone)
      end
    end
  end

  describe "clients" do
    test "see a voice agent's state and transcript", ctx do
      %{alice: alice} = start(ctx)

      assert_receive {:octoroom, _,
                      {:worker, :updated,
                       %{id: "assistant", state: "listening", attributes: %{name: "Assistant"}}}}

      say(ctx, alice, {:final, "Hi!"})

      assert_receive {:octoroom, _, {:worker, :updated, %{state: "thinking"}}}

      assert_receive {:octoroom, _,
                      {:worker_notify, "assistant", "assistant", "transcript",
                       %{role: "user", text: "Hi!", speaker: "Alice", message_id: _}}}

      assert_receive {:octoroom, _, {:worker, :updated, %{state: "speaking"}}}, 1_000

      assert_receive {:octoroom, _,
                      {:worker_notify, "assistant", "assistant", "transcript",
                       %{role: "assistant", text: "Hello there.", status: "completed"}}},
                     1_000

      # Once its 200 ms of audio has played.
      assert_receive {:octoroom, _, {:worker, :updated, %{state: "listening"}}}, 1_000
    end

    # A text-only agent that never answers on its own: only typed messages
    # get a reply.
    defp text_agent(ctx) do
      meta = %{
        name: "Alice",
        args: args(self(), 0),
        agent: [voice: false, respond: :never, description: "Takes notes."]
      }

      alice = join(ctx, "alice", meta)
      hear(ctx, alice)
    end

    test "a text-only agent catches subscribers up, and answers what they type", ctx do
      alice = text_agent(ctx)

      # Seen as soon as the room starts it; its presence follows.
      assert_receive {:client, "alice",
                      {:octoroom_signal, :worker,
                       %{op: :added, worker: %{id: "assistant", outputs: [], data: ["assistant"]}}}}

      assert_receive {:client, "alice",
                      {:octoroom_signal, :worker,
                       %{
                         op: :updated,
                         worker: %{state: "listening", attributes: %{description: "Takes notes."}}
                       }}}

      assert_receive {:client, "alice",
                      {:octoroom_signal, :worker_event,
                       %{type: "transcript_snapshot", data: %{items: []}}}}

      # Spoken, it only listens.
      say(ctx, alice, {:final, "Note that down."})

      assert_receive {:client, "alice",
                      {:octoroom_signal, :worker_event,
                       %{type: "transcript", data: %{role: "user", text: "Note that down."}}}}

      refute_receive {:llm, _}, 100

      # Typed, it answers, with Alice as the speaker.
      Server.worker_message(alice.server, alice.id, "assistant", %{"text" => "What's up?"}, :msg)
      assert_receive {:client, "alice", {:octoroom_signal, :reply, :msg, {:ok, %{}}}}
      assert_receive {:llm, messages}
      assert List.last(messages) == "[Alice] What's up?"

      assert_receive {:client, "alice",
                      {:octoroom_signal, :worker_event,
                       %{type: "transcript", data: %{role: "user", text: "What's up?"}}}}

      assert_receive {:client, "alice",
                      {:octoroom_signal, :worker_event,
                       %{
                         type: "transcript",
                         data: %{role: "assistant", text: "Hello there.", status: "completed"}
                       }}},
                     1_000

      # Someone who joins now gets the conversation so far.
      join(ctx, "bob", %{name: "Bob"})

      assert_receive {:client, "bob",
                      {:octoroom_signal, :worker_event,
                       %{type: "transcript_snapshot", data: %{items: items}}}},
                     1_000

      assert Enum.map(items, &{&1.role, &1.text}) == [
               {"user", "Note that down."},
               {"user", "What's up?"},
               {"assistant", "Hello there."}
             ]

      # Only text is answered.
      Server.worker_message(alice.server, alice.id, "assistant", %{"draw" => "a cat"}, :msg2)
      assert_receive {:client, "alice", {:octoroom_signal, :reply, :msg2, {:ok, %{}}}}
      refute_receive {:llm, _}, 100
    end
  end

  describe "Gemini Live (mixed)" do
    # The agent's back end is Gemini Live with its socket replaced: what it
    # would send comes here as `{:to_gemini, message}`, and `live/2` plays
    # the model's events.
    defp live_args(test) do
      back =
        processor(:gemini, Processors.GeminiLive,
          model: "gemini-live-x",
          send: &send(test, {:to_gemini, &1})
        )

      %{name: "Assistant", front_end: nil, back_end: back}
    end

    defp start_live(ctx) do
      Octoroom.subscribe(ctx.room_id, scope: :room)
      alice = join(ctx, "alice", %{name: "Alice", args: live_args(self())})
      cf = agent_track(alice.mic)
      wait_until(fn -> match?([%{connected: [_ | _]}], workers(ctx)) end)
      live(ctx, :setup_complete)
      %{alice: alice, cf_track: cf}
    end

    defp live(ctx, event),
      do: :ok = Octoroom.Worker.send(ctx.room_id, "assistant", {:gemini_live_socket, event})

    defp speak(ctx, client, frames),
      do:
        for(
          _ <- 1..frames,
          do: FakeCloudflare.egress(ctx.fake, client.session, client.mic, @frame)
        )

    # Chunks the model hears until one has `value` in it.
    defp hears_sample(value) do
      assert_receive {:to_gemini, {:audio, pcm}}, 1_000
      assert byte_size(pcm) == 640
      if value in for(<<s::signed-little-16 <- pcm>>, do: s), do: :ok, else: hears_sample(value)
    end

    test "hears everyone mixed into one stream", ctx do
      %{alice: alice} = start_live(ctx)
      speak(ctx, alice, 4)
      hears_sample(1)

      bob = join(ctx, "bob", %{name: "Bob"})
      wait_until(fn -> bob.mic in hd(workers(ctx)).connected end)

      for _ <- 1..5 do
        speak(ctx, alice, 1)
        speak(ctx, bob, 1)
      end

      # Both at once: their samples add up.
      hears_sample(2)
    end

    test "passes on all of a speaker's audio, in real time", ctx do
      # The fake client never answers signaling, which the room gives up on
      # after `signal_timeout` and stops hearing Alice: longer than the test.
      ctx = %{ctx | opts: Keyword.put(ctx.opts, :signal_timeout, 10_000)}
      %{alice: alice} = start_live(ctx)
      started = System.monotonic_time(:millisecond)

      # Two seconds of Alice, a 20 ms frame every 20 ms.
      for n <- 1..100 do
        speak(ctx, alice, 1)
        Process.sleep(max(started + n * 20 - System.monotonic_time(:millisecond), 0))
      end

      Process.sleep(200)
      sent = count_audio(0)

      # All of it but what's still buffered (under two 20 ms chunks).
      assert sent >= 98 * 640 and sent <= 100 * 640,
             "Gemini got #{div(sent, 32)} ms of 2000 ms"
    end

    defp count_audio(bytes) do
      receive do
        {:to_gemini, {:audio, pcm}} -> count_audio(bytes + byte_size(pcm))
      after
        0 -> bytes
      end
    end

    test "speaks what the model says, with its state and transcript", ctx do
      %{cf_track: cf} = start_live(ctx)

      live(ctx, {:transcription, :user, "Hi!", true})

      assert_receive {:octoroom, _,
                      {:worker_event, "assistant",
                       {:agent, {:conversation, %{role: "user", text: "Hi!"}}}}}

      live(ctx, {:audio, :binary.copy(<<0, 0>>, 24 * 200), sample_rate: 24_000})
      live(ctx, {:transcription, :assistant, "Hello.", false})
      live(ctx, :turn_complete)

      assert_receive {:octoroom, _, {:worker, :updated, %{state: "speaking"}}}, 1_000
      assert_receive {:ingest, ^cf, frame}, 1_000
      assert byte_size(frame) == 3_840

      assert_receive {:octoroom, _,
                      {:worker_notify, "assistant", "assistant", "transcript",
                       %{role: "assistant", text: "Hello.", status: "completed"}}}

      # Once its 200 ms has played.
      assert_receive {:octoroom, _, {:worker, :updated, %{state: "listening"}}}, 1_000
    end

    test "someone talking over a reply that's still playing stops it", ctx do
      start_live(ctx)

      live(ctx, {:audio, :binary.copy(<<0, 0>>, 24 * 3_000), sample_rate: 24_000})
      live(ctx, :turn_complete)
      assert_receive {:octoroom, _, {:worker, :updated, %{state: "speaking"}}}, 1_000

      live(ctx, {:transcription, :user, "Wait", false})
      assert_receive {:octoroom, _, {:worker, :updated, %{state: "listening"}}}, 500
    end

    test "typed messages and the app's prompts reach the model as text", ctx do
      %{alice: alice} = start_live(ctx)

      Server.worker_message(alice.server, alice.id, "assistant", %{"text" => "What's up?"}, :msg)
      assert_receive {:to_gemini, {:text, "[Alice] What's up?"}}

      assert_receive {:octoroom, _,
                      {:worker_event, "assistant",
                       {:agent,
                        {:conversation, %{role: "user", text: "What's up?", speaker: "Alice"}}}}}

      :ok = Octoroom.Agent.prompt(ctx.room_id, "assistant", "Sum up.")

      assert_receive {:to_gemini,
                      {:text, "[From the app, not said by anyone on the call] Sum up."}}
    end

    test "a restarted agent resumes its Gemini session", ctx do
      start_live(ctx)
      assert_receive {:to_gemini, {:connect, [handle: nil, fallback_setup: _]}}

      live(ctx, {:transcription, :user, "I'm Alice.", true})
      live(ctx, {:resumption, "h1"})

      wait_until(fn ->
        match?(
          %{gemini_handle: %{handle: "h1"}, items: [_]},
          Octoroom.Worker.saved(ctx.room_id, "assistant")
        )
      end)

      pid = Octoroom.Worker.whereis(ctx.room_id, "assistant")
      Process.exit(pid, :kill)

      assert_receive {:to_gemini, {:connect, connect}}, 2_000
      assert connect[:handle] == "h1"
      assert connect[:fallback_setup][:system_instruction] =~ "[someone] I'm Alice."
    end

    test "a module picks it as its pipeline, and it can't be silent" do
      defmodule LiveAgent do
        use Octoroom.Agent

        @impl true
        def pipeline(_ctx),
          do: Octoroom.Agent.Pipeline.Spec.gemini_live(voice: "Puck", model: "gemini-live-x")
      end

      assert {:stop, :voice_false_needs_text_to_speech} =
               Octoroom.Agent.Worker.init(
                 %{agent: LiveAgent, args: %{}, voice: false},
                 %Octoroom.Worker.Context{room_id: "r", id: "a", inputs: [], outputs: []}
               )
    end
  end

  describe "OpenAI Live (mixed)" do
    defp openai_live_args(test) do
      back =
        processor(:openai, Processors.OpenAILive,
          model: "gpt-live-1.1",
          send: &send(test, {:to_openai, &1})
        )

      %{name: "Assistant", front_end: nil, back_end: back}
    end

    defp start_openai_live(ctx) do
      Octoroom.subscribe(ctx.room_id, scope: :room)
      alice = join(ctx, "alice", %{name: "Alice", args: openai_live_args(self())})
      cf = agent_track(alice.mic)
      wait_until(fn -> match?([%{connected: [_ | _]}], workers(ctx)) end)
      openai_live(ctx, {:session_started, %{"id" => "live_1"}})
      %{alice: alice, cf_track: cf}
    end

    defp openai_live(ctx, event),
      do: :ok = Octoroom.Worker.send(ctx.room_id, "assistant", {:openai_live_socket, event})

    test "mixes inputs and resamples 16 kHz to 24 kHz for OpenAI Live", ctx do
      %{alice: alice} = start_openai_live(ctx)
      speak(ctx, alice, 4)

      assert_receive {:to_openai, {:audio, pcm}}, 1_000
      # 20 ms at 24 kHz mono s16le = 480 samples = 960 bytes.
      assert byte_size(pcm) == 960
    end

    test "speaks what the model says, with its state and transcript", ctx do
      %{cf_track: cf} = start_openai_live(ctx)

      openai_live(ctx, {:transcription, :user, "Hi!"})
      openai_live(ctx, {:audio, :binary.copy(<<0, 0>>, 24 * 200), sample_rate: 24_000})
      openai_live(ctx, {:transcription, :assistant, "Hello."})

      assert_receive {:octoroom, _,
                      {:worker_event, "assistant",
                       {:agent, {:conversation, %{role: "user", text: "Hi!"}}}}}

      assert_receive {:octoroom, _, {:worker, :updated, %{state: "speaking"}}}, 1_000
      assert_receive {:ingest, ^cf, frame}, 1_000
      assert byte_size(frame) == 3_840

      assert_receive {:octoroom, _,
                      {:worker_notify, "assistant", "assistant", "transcript",
                       %{role: "assistant", text: "Hello.", status: "completed"}}},
                     1_500

      assert_receive {:octoroom, _, {:worker, :updated, %{state: "listening"}}}, 1_500
    end

    test "typed messages, prompts and restart transcript carry over", ctx do
      %{alice: alice} = start_openai_live(ctx)
      assert_receive {:to_openai, {:connect, [setup: _]}}

      Server.worker_message(alice.server, alice.id, "assistant", %{"text" => "What's up?"}, :msg)
      assert_receive {:to_openai, {:commentary, "[Alice] What's up?"}}

      wait_until(fn ->
        match?(%{items: [_]}, Octoroom.Worker.saved(ctx.room_id, "assistant"))
      end)

      :ok = Octoroom.Agent.prompt(ctx.room_id, "assistant", "Sum up.")

      assert_receive {:to_openai,
                      {:commentary, "[From the app, not said by anyone on the call] Sum up."}}

      pid = Octoroom.Worker.whereis(ctx.room_id, "assistant")
      Process.exit(pid, :kill)

      assert_receive {:to_openai, {:connect, connect}}, 2_000
      assert connect[:setup][:instructions] =~ "[Alice] What's up?"
    end

    test "a module picks openai_live as its pipeline, and it can't be silent" do
      defmodule OpenAILiveAgent do
        use Octoroom.Agent

        @impl true
        def pipeline(_ctx),
          do: Octoroom.Agent.Pipeline.Spec.openai_live(voice: "marin", model: "gpt-live-1.1")
      end

      assert {:stop, :voice_false_needs_text_to_speech} =
               Octoroom.Agent.Worker.init(
                 %{agent: OpenAILiveAgent, args: %{}, voice: false},
                 %Octoroom.Worker.Context{room_id: "r", id: "a", inputs: [], outputs: []}
               )
    end
  end

  test "a pipeline that can't speak at 24 kHz or hear 16 kHz doesn't start", ctx do
    worker_ctx = %Octoroom.Worker.Context{room_id: ctx.room_id, id: "a", inputs: [], outputs: []}
    tts = [provider: :inworld, model: "inworld-tts-2", output_sample_rate: 16_000]
    {front, back} = default(Keyword.put(@providers, :tts, tts))

    assert {:stop, {:unsupported_output_sample_rate, 16_000}} =
             Octoroom.Agent.Worker.init(%{front_end: front, back_end: back}, worker_ctx)

    stt = [provider: :soniox, model: "stt-rt-v6", sample_rate: 8_000]
    {front, back} = default(Keyword.put(@providers, :stt, stt))

    assert {:stop, {:unsupported_input_sample_rate, 8_000}} =
             Octoroom.Agent.Worker.init(%{front_end: front, back_end: back}, worker_ctx)
  end

  test "the decision gate adds a decision stage to a front end without one", ctx do
    worker_ctx = %Octoroom.Worker.Context{room_id: ctx.room_id, id: "a", inputs: [], outputs: []}
    args = args(self(), 200)
    bare = remove(args.front_end, :decisions)

    front_spec = fn args ->
      assert {:ok, state, _actions} = Octoroom.Agent.Worker.init(args, worker_ctx)
      state.front_spec
    end

    assert names(front_spec.(%{args | front_end: bare})) == [:stt, :turns]

    gate = %{front_end: bare, gate: :decision}
    gated = front_spec.(Map.merge(args, Map.put(gate, :decisions, model: "google:some-model")))
    assert names(gated) == [:stt, :turns, :decisions]
    assert List.last(gated.stages).module == Processors.Decisions
    assert Keyword.fetch!(opts(gated, :decisions), :model) == "google:some-model"

    # It picks no model.
    assert {:stop, :decisions_need_a_model} =
             Octoroom.Agent.Worker.init(Map.merge(args, gate), worker_ctx)

    # One of its own is left alone.
    kept = front_spec.(Map.put(args, :gate, :decision))
    assert List.last(kept.stages).module == NoDecisions
  end

  test "an agent with no pipeline doesn't start", ctx do
    assert {:stop, :no_pipeline} =
             Octoroom.Agent.Worker.init(
               %{instructions: "Be brief."},
               %Octoroom.Worker.Context{room_id: ctx.room_id, id: "a", inputs: [], outputs: []}
             )
  end

  test "a module's pipeline/1 must return both parts" do
    defmodule NoPipeline do
      use Octoroom.Agent

      @impl true
      def pipeline(_ctx), do: nil
    end

    assert_raise ArgumentError, ~r/pipeline\/1 must return/, fn ->
      Octoroom.Agent.Worker.init(
        %{agent: NoPipeline, args: %{}},
        %Octoroom.Worker.Context{room_id: "r", id: "a", inputs: [], outputs: []}
      )
    end
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never became true")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
  end
end
