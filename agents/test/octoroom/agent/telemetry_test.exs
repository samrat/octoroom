defmodule Octoroom.Agent.TelemetryTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.{Frames, Processors, Telemetry, Tool, ToolDispatcher}
  alias Octoroom.Agent.Pipeline.Core
  alias Octoroom.Agent.Pipeline.Test, as: Harness

  defp attach(events, tag) do
    test = self()
    handler = {__MODULE__, tag, make_ref()}

    :telemetry.attach_many(
      handler,
      events,
      fn event, measurements, meta, _ ->
        if meta[:room_id] == tag do
          send(test, {:telemetry, event, measurements, meta})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    handler
  end

  defp tag, do: "room-#{System.unique_integer([:positive])}"

  describe "streaming async stages (LLM & TTS)" do
    test "emits start, first_output (ignoring non-pushing events), and stop with outputs" do
      room = tag()
      attach(Telemetry.events(), room)

      llm_request = fn _opts, emit ->
        # Metadata and thinking deltas push no frames, so they must not trigger :first_output.
        emit.({:metadata, %{id: "m1"}})
        emit.({:thinking_delta, "hmm"})
        emit.({:text_delta, "Hello "})
        emit.({:text_delta, "world."})
        {:ok, %{text: "Hello world.", function_calls: [], continuation: []}}
      end

      tts_synth = fn _text, on_audio ->
        on_audio.(<<1, 0, 2, 0>>)
        on_audio.(<<3, 0, 4, 0>>)
        :ok
      end

      processor(:llm, Processors.LLM,
        provider: :google,
        model: "gemini-test",
        request: llm_request
      )
      |> processor(:chunker, Processors.TextChunker)
      |> processor(:tts, Processors.TTS,
        model: "inworld-test",
        voice: "Ashley",
        synthesize: tts_synth
      )
      |> Harness.run(
        [%Frames.LLMContext{messages: [%{role: "user", content: "hi"}], tools: []}],
        ctx: %{telemetry: %{room_id: room, agent_id: "assistant"}}
      )

      # LLM: start -> first_output (on first LLMText) -> stop
      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :start],
                       %{system_time: _, monotonic_time: _},
                       %{
                         room_id: ^room,
                         agent_id: "assistant",
                         processor: :llm,
                         task: :reply,
                         provider: :google,
                         model: "gemini-test",
                         stream: true,
                         message_count: 1,
                         tool_count: 0,
                         trigger: Frames.LLMContext
                       }}

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :first_output],
                       %{duration: ttft, monotonic_time: _},
                       %{
                         processor: :llm,
                         task: :reply,
                         frame: Frames.LLMText,
                         model: "gemini-test"
                       }}

      assert ttft >= 0

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :stop],
                       %{duration: total, first_output_duration: ^ttft, outputs: 2},
                       %{
                         processor: :llm,
                         task: :reply,
                         status: :ok,
                         provider: :google,
                         model: "gemini-test"
                       }}

      assert total >= ttft

      # TTS: start -> first_output (on first OutputAudio) -> stop
      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :start], _,
                       %{
                         processor: :tts,
                         task: :speak,
                         model: "inworld-test",
                         voice: "Ashley",
                         chars: chars
                       }}

      assert chars > 0

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :first_output],
                       %{duration: ttfb},
                       %{processor: :tts, task: :speak, frame: Frames.OutputAudio}}

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :stop],
                       %{duration: tts_total, first_output_duration: ^ttfb, outputs: 2},
                       %{processor: :tts, task: :speak, status: :ok}}

      assert tts_total >= ttfb
    end
  end

  describe "single-shot async stages (Decisions, Transcriber, Tools)" do
    test "Decisions emits start and stop with modality, audio_ms, and model without first_output" do
      room = tag()
      attach(Telemetry.events(), room)

      answers = %{
        "addressee" => %{"choice" => "assistant", "confidence" => 0.9, "probabilities" => %{}},
        "answerable" => %{"probability" => 0.8}
      }

      processor(:decisions, Processors.Decisions,
        model: "google:gemini-decision-1",
        questions_id: :intake,
        evaluate: fn _wav -> {:ok, answers} end
      )
      |> Harness.run(
        [%Frames.UserAudio{turn_id: 3, audio: :binary.copy(<<0, 0>>, 8_000)}],
        ctx: %{telemetry: %{room_id: room, agent_id: "assistant", input: "alice/mic"}}
      )

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :start], _,
                       %{
                         room_id: ^room,
                         agent_id: "assistant",
                         input: "alice/mic",
                         processor: :decisions,
                         task: :evaluate,
                         model: "google:gemini-decision-1",
                         modality: :audio,
                         audio_ms: 500,
                         questions_id: :intake
                       }}

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :stop],
                       %{duration: d, outputs: 0} = m,
                       %{processor: :decisions, task: :evaluate, status: :ok}}

      assert d >= 0
      refute Map.has_key?(m, :first_output_duration)
      refute_received {:telemetry, [:octoroom_agent, :processor, :async, :first_output], _, _}
    end

    test "Transcriber emits start and stop with turn_id, audio_ms, and uninterruptible: true" do
      room = tag()
      attach(Telemetry.events(), room)

      processor(:transcriber, Processors.Transcriber,
        model: "gemini-3.1-flash-lite",
        transcribe: fn _pcm, _rate -> {:ok, "hello"} end
      )
      |> Harness.run(
        [
          %Frames.UserAudio{
            turn_id: 9,
            audio: :binary.copy(<<0, 0>>, 16_000),
            sample_rate: 16_000
          }
        ],
        ctx: %{telemetry: %{room_id: room, agent_id: "assistant"}}
      )

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :start], _,
                       %{
                         processor: :transcriber,
                         task: :transcribe,
                         model: "gemini-3.1-flash-lite",
                         turn_id: 9,
                         audio_ms: 1_000,
                         uninterruptible: true
                       }}

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :stop],
                       %{duration: _, outputs: 0},
                       %{processor: :transcriber, task: :transcribe, status: :ok}}
    end

    test "Tools stage emits async span and ToolDispatcher emits per-tool spans" do
      room = tag()
      attach(Telemetry.events(), room)

      defmodule DemoTools do
        def ok_tool(call, _ctx), do: %{id: call.id, name: call.name, response: %{ok: true}}

        def err_tool(call, _ctx),
          do: %{id: call.id, name: call.name, response: %{result: "error", reason: "nope"}}
      end

      tools = [
        %Tool{name: "lookup", description: "d", parameters: %{}, handler: {DemoTools, :ok_tool}},
        %Tool{name: "fail", description: "d", parameters: %{}, handler: {DemoTools, :err_tool}}
      ]

      calls = [
        %{id: "c1", name: "lookup", args: %{}},
        %{id: "c2", name: "fail", args: %{}},
        %{id: "c3", name: "missing", args: %{}}
      ]

      processor(:tools, Processors.Tools, tools: tools)
      |> Harness.run(
        [%Frames.ToolCalls{calls: calls, provider: :google}],
        ctx: %{
          telemetry: %{room_id: room, agent_id: "assistant"},
          context: %{room_id: room, agent_id: "assistant"}
        }
      )

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :start], _,
                       %{
                         processor: :tools,
                         task: :run,
                         provider: :google,
                         sync_tools: ["lookup", "fail", "missing"],
                         async_tools: [],
                         call_count: 3
                       }}

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :stop], _,
                       %{processor: :tools, task: :run, status: :ok}}

      assert_received {:telemetry, [:octoroom_agent, :tool, :call, :stop], %{duration: _},
                       %{room_id: ^room, tool: "lookup", call_id: "c1", result: :ok}}

      assert_received {:telemetry, [:octoroom_agent, :tool, :call, :stop], %{duration: _},
                       %{room_id: ^room, tool: "fail", call_id: "c2", result: :error}}

      assert_received {:telemetry, [:octoroom_agent, :tool, :call, :stop], %{duration: _},
                       %{room_id: ^room, tool: "missing", call_id: "c3", result: :unknown}}
    end

    test "ToolDispatcher emits :exception when a handler raises" do
      room = tag()
      attach(Telemetry.events(), room)

      defmodule CrashTool do
        def boom(_call, _ctx), do: raise("kaboom")
      end

      tools = [
        %Tool{name: "boom", description: "d", parameters: %{}, handler: {CrashTool, :boom}}
      ]

      assert_raise RuntimeError, "kaboom", fn ->
        ToolDispatcher.handle_calls(
          [%{id: "c1", name: "boom", args: %{}}],
          tools,
          %{room_id: room, agent_id: "assistant"}
        )
      end

      assert_received {:telemetry, [:octoroom_agent, :tool, :call, :exception], %{duration: _},
                       %{room_id: ^room, tool: "boom", kind: :error, reason: %RuntimeError{}}}
    end
  end

  describe "non-ok async lifecycle closures (error, exception, cancel, interrupt, terminate)" do
    test "returning {:error, reason} closes with status: :error" do
      room = tag()
      attach(Telemetry.events(), room)

      processor(:llm, Processors.LLM,
        provider: :google,
        model: "gemini-test",
        request: fn _opts, _emit -> {:error, :rate_limited} end
      )
      |> Harness.run(
        [%Frames.LLMContext{messages: [], tools: []}],
        ctx: %{telemetry: %{room_id: room, agent_id: "assistant"}}
      )

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :stop], _,
                       %{processor: :llm, task: :reply, status: :error, reason: :rate_limited}}
    end

    test "crashing task closes with :exception" do
      room = tag()
      attach(Telemetry.events(), room)

      processor(:llm, Processors.LLM,
        provider: :google,
        model: "gemini-test",
        request: fn _opts, _emit -> raise "boom" end
      )
      |> Harness.run(
        [%Frames.LLMContext{messages: [], tools: []}],
        ctx: %{telemetry: %{room_id: room, agent_id: "assistant"}}
      )

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :exception],
                       %{duration: _, outputs: 0},
                       %{
                         processor: :llm,
                         task: :reply,
                         kind: :error,
                         reason: %RuntimeError{message: "boom"}
                       }}
    end

    test "interruption closes interruptible tasks with status: :interrupted and preserves uninterruptible ones" do
      room = tag()
      attach(Telemetry.events(), room)

      harness =
        processor(:transcriber, Processors.Transcriber,
          model: "gemini-lite",
          transcribe: fn _pcm, _rate -> {:ok, "kept"} end
        )
        |> processor(:llm, Processors.LLM,
          provider: :google,
          model: "gemini-test",
          request: fn _opts, _emit ->
            {:ok, %{text: "hi", function_calls: [], continuation: []}}
          end
        )
        |> Harness.start!(
          async: :manual,
          ctx: %{telemetry: %{room_id: room, agent_id: "assistant"}}
        )
        |> Harness.push(%Frames.UserAudio{turn_id: 1, audio: <<0, 0>>, sample_rate: 16_000})
        |> Harness.push(%Frames.LLMContext{messages: [], tools: []})
        |> Harness.push(%Frames.Interruption{})

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :stop], _,
                       %{processor: :llm, task: :reply, status: :interrupted}}

      refute_received {:telemetry, [:octoroom_agent, :processor, :async, :stop], _,
                       %{processor: :transcriber}}

      # Terminating closes any still-running tasks with :terminated.
      Core.terminate(harness.core, :normal)

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :stop], _,
                       %{
                         processor: :transcriber,
                         task: :transcribe,
                         status: :terminated,
                         reason: :normal
                       }}
    end

    test "cancelling or replacing an in-flight key closes the old task with status: :cancelled" do
      room = tag()
      attach(Telemetry.events(), room)

      processor(:llm, Processors.LLM,
        provider: :google,
        model: "gemini-test",
        request: fn _opts, _emit -> {:ok, %{text: "hi", function_calls: [], continuation: []}} end
      )
      |> Harness.start!(
        async: :manual,
        ctx: %{telemetry: %{room_id: room, agent_id: "assistant"}}
      )
      |> Harness.push(%Frames.LLMContext{messages: [], tools: []})
      |> Harness.push(%Frames.LLMContext{messages: [], tools: []})

      assert_received {:telemetry, [:octoroom_agent, :processor, :async, :stop], _,
                       %{processor: :llm, task: :reply, status: :cancelled}}
    end
  end

  describe "Octoroom.Agent.Telemetry helpers" do
    test "events/0 lists all events and format/3 formats them cleanly" do
      assert [:octoroom_agent, :processor, :async, :start] in Telemetry.events()
      assert [:octoroom_agent, :processor, :async, :first_output] in Telemetry.events()
      assert [:octoroom_agent, :processor, :async, :stop] in Telemetry.events()
      assert [:octoroom_agent, :processor, :async, :exception] in Telemetry.events()
      assert [:octoroom_agent, :tool, :call, :stop] in Telemetry.events()
      assert [:octoroom_agent, :turn, :latency] in Telemetry.events()

      dur = System.convert_time_unit(412, :millisecond, :native)
      first = System.convert_time_unit(148, :millisecond, :native)

      line =
        Telemetry.format(
          [:octoroom_agent, :processor, :async, :stop],
          %{duration: dur, first_output_duration: first, outputs: 12},
          %{
            room_id: "room-1",
            agent_id: "assistant",
            processor: :llm,
            task: :reply,
            status: :ok,
            provider: :google,
            model: "gemini-3.5-flash"
          }
        )

      assert line ==
               "Octoroom.Agent room-1/assistant llm:reply ok in 412 ms " <>
                 "(first 148 ms, 12 outputs, google/gemini-3.5-flash)"

      turn_line =
        Telemetry.format(
          [:octoroom_agent, :turn, :latency],
          %{transcript_ms: 320, llm_ms: 510, audio_ms: 680},
          %{room_id: "room-1", agent_id: "assistant"}
        )

      assert turn_line ==
               "Octoroom.Agent room-1/assistant turn latency: " <>
                 "transcript 320 ms, llm 510 ms, audio 680 ms"
    end

    test "attach_default_logger/1 and detach_default_logger/0 attach and detach cleanly" do
      # Ensure clean state if another test touched it.
      Telemetry.detach_default_logger()
      assert :ok = Telemetry.attach_default_logger(level: :debug)
      assert {:error, :already_exists} = Telemetry.attach_default_logger()
      assert :ok = Telemetry.detach_default_logger()
    end
  end

  describe "live speech-to-speech telemetry (OpenAI Live & Gemini Live)" do
    test "OpenAILive emits session and response start/first_audio/stop events" do
      room = tag()
      attach(Telemetry.events(), room)

      harness =
        processor(:openai, Processors.OpenAILive,
          model: "gpt-live-1.1",
          voice: "marin",
          send: fn _ -> :ok end
        )
        |> Harness.start!(ctx: %{telemetry: %{room_id: room, agent_id: "openai"}})
        |> Harness.info(:openai, {:openai_live_socket, {:session_started, %{}}})
        |> Harness.info(:openai, {:openai_live_socket, {:transcription, :user, "OpenAI hi"}})
        |> Harness.info(
          :openai,
          {:openai_live_socket, {:audio, :binary.copy(<<1, 0>>, 480), sample_rate: 24_000}}
        )
        |> Harness.info(:openai, {:openai_live_socket, {:transcription, :assistant, "Hey!"}})
        |> Harness.info(:openai, {:openai_live_socket, {:session_paused, %{}}})

      assert harness != nil

      assert_received {:telemetry, [:octoroom_agent, :live, :session], %{duration_ms: d},
                       %{
                         room_id: ^room,
                         agent_id: "openai",
                         provider: :openai,
                         model: "gpt-live-1.1",
                         transport: :webrtc,
                         event: :started
                       }}

      assert d >= 0

      assert_received {:telemetry, [:octoroom_agent, :live, :response, :start], _,
                       %{room_id: ^room, agent_id: "openai", provider: :openai}}

      assert_received {:telemetry, [:octoroom_agent, :live, :response, :first_audio],
                       %{response_latency_ms: lat},
                       %{room_id: ^room, agent_id: "openai", provider: :openai}}

      assert lat >= 0

      assert_received {:telemetry, [:octoroom_agent, :live, :response, :stop],
                       %{duration_ms: _, audio_ms: 20, outputs: 1, response_latency_ms: ^lat},
                       %{
                         room_id: ^room,
                         agent_id: "openai",
                         provider: :openai,
                         model: "gpt-live-1.1",
                         status: :ok,
                         user_text: "OpenAI hi",
                         assistant_text: "Hey!"
                       }}
    end

    test "GeminiLive emits session and response stop events" do
      room = tag()
      attach(Telemetry.events(), room)

      processor(:gemini, Processors.GeminiLive,
        model: "gemini-3.8-live",
        voice: "Puck",
        send: fn _ -> :ok end
      )
      |> Harness.start!(ctx: %{telemetry: %{room_id: room, agent_id: "gemini"}})
      |> Harness.info(:gemini, {:gemini_live_socket, :setup_complete})
      |> Harness.info(:gemini, {:gemini_live_socket, {:transcription, :user, "Hi Gemini", true}})
      |> Harness.info(
        :gemini,
        {:gemini_live_socket, {:audio, :binary.copy(<<1, 0>>, 480), sample_rate: 24_000}}
      )
      |> Harness.info(
        :gemini,
        {:gemini_live_socket, {:transcription, :assistant, "Hello!", true}}
      )
      |> Harness.info(:gemini, {:gemini_live_socket, :turn_complete})

      assert_received {:telemetry, [:octoroom_agent, :live, :session], %{duration_ms: _},
                       %{room_id: ^room, agent_id: "gemini", provider: :gemini, event: :started}}

      assert_received {:telemetry, [:octoroom_agent, :live, :response, :stop],
                       %{audio_ms: 20, outputs: 1, response_latency_ms: _},
                       %{
                         room_id: ^room,
                         agent_id: "gemini",
                         provider: :gemini,
                         status: :ok,
                         user_text: "Hi Gemini",
                         assistant_text: "Hello!"
                       }}
    end
  end
end
