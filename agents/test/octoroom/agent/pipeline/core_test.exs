defmodule Octoroom.Agent.Pipeline.CoreTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Core
  alias Octoroom.Agent.Pipeline.Test, as: Harness

  defmodule Upcase do
    use Octoroom.Agent.Processor

    @impl true
    def handle_frame(%Frames.LLMText{} = frame, :downstream, state),
      do: {[{:push, %{frame | text: String.upcase(frame.text)}, :downstream}], state}

    def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}
  end

  # Records every frame it sees, in order.
  defmodule Recorder do
    use Octoroom.Agent.Processor

    @impl true
    def init(_opts, _ctx), do: {:ok, []}

    @impl true
    def handle_frame(frame, direction, seen),
      do: {[{:push, frame, direction}], seen ++ [frame.__struct__]}
  end

  # On LLMText, emits a data frame and then a system frame.
  defmodule DataThenSystem do
    use Octoroom.Agent.Processor

    @impl true
    def handle_frame(%Frames.LLMText{}, :downstream, state) do
      {[
         {:push, %Frames.Text{text: "data"}, :downstream},
         {:push, %Frames.UserStartedSpeaking{}, :downstream}
       ], state}
    end

    def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}
  end

  # Streams a reply for LLMContext; records interruptions and sends the partial
  # reply upstream when interrupted.
  defmodule FakeLLM do
    use Octoroom.Agent.Processor

    @impl true
    def init(opts, _ctx), do: {:ok, %{words: Keyword.fetch!(opts, :words), text: ""}}

    @impl true
    def handle_frame(%Frames.LLMContext{}, :downstream, state) do
      words = state.words

      stream = fn emit ->
        Enum.each(words, &emit.({:text, &1}))
        :finished
      end

      {[{:push, %Frames.LLMResponseStart{}, :downstream}, {:async, :reply, stream}],
       %{state | text: ""}}
    end

    def handle_frame(%Frames.Interruption{}, _direction, %{text: ""} = state), do: {[], state}

    def handle_frame(%Frames.Interruption{}, _direction, state) do
      message = %Frames.AssistantMessage{text: state.text, interrupted?: true}
      {[{:push, message, :upstream}], %{state | text: ""}}
    end

    def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

    @impl true
    def handle_async(:reply, {:text, word}, state),
      do:
        {[{:push, %Frames.LLMText{text: word}, :downstream}], %{state | text: state.text <> word}}

    def handle_async(:reply, {:done, :finished}, state),
      do: {[{:push, %Frames.LLMResponseEnd{}, :downstream}], %{state | text: ""}}
  end

  # Starts a slow "transcription" task for every UserAudio (uninterruptible).
  defmodule Transcriber do
    use Octoroom.Agent.Processor

    @impl true
    def handle_frame(%Frames.UserAudio{turn_id: turn_id} = frame, :downstream, state) do
      {[{:push, frame, :downstream}, {:async, {:transcribe, turn_id}, fn _emit -> "hello" end}],
       state}
    end

    def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

    @impl true
    def handle_async({:transcribe, turn_id}, {:done, text}, state),
      do: {[{:push, %Frames.Transcription{turn_id: turn_id, text: text}, :downstream}], state}
  end

  # Waits for silence with a timer, like a turn detector.
  defmodule SilenceTimer do
    use Octoroom.Agent.Processor

    @impl true
    def init(_opts, _ctx), do: {:ok, :idle}

    @impl true
    def handle_frame(%Frames.VADUserStoppedSpeaking{}, :downstream, _state),
      do: {[{:timer, :silence, 2_000}], :paused}

    def handle_frame(%Frames.VADUserStartedSpeaking{}, :downstream, :paused),
      do: {[{:cancel_timer, :silence}], :idle}

    def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

    @impl true
    def handle_timer(:silence, :paused),
      do: {[{:push, %Frames.UserStoppedSpeaking{turn_id: 1}, :downstream}], :idle}
  end

  defmodule Crash do
    use Octoroom.Agent.Processor

    @impl true
    def handle_frame(%Frames.Text{}, _direction, _state), do: raise("boom")
    def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}
  end

  defmodule Notifier do
    use Octoroom.Agent.Processor

    @impl true
    def handle_info({:socket, text}, state), do: {[{:notify, {:heard, text}}], state}
  end

  test "frames pass through the chain in order and get ids" do
    harness =
      processor(:upcase, Upcase)
      |> processor(:recorder, Recorder)
      |> Harness.run([%Frames.LLMText{text: "hi"}, %Frames.LLMText{text: "there"}])

    assert [%Frames.LLMText{text: "HI", id: id1}, %Frames.LLMText{text: "THERE", id: id2}] =
             Harness.outputs(harness)

    assert is_integer(id1) and id2 > id1
    assert Harness.state(harness, :recorder) == [Frames.LLMText, Frames.LLMText]
  end

  test "upstream frames reach earlier stages and stop at the first" do
    harness =
      processor(:first, Recorder)
      |> processor(:second, Upcase)
      |> Harness.run([%Frames.FinalizeTranscript{}], [])
      |> Harness.push(%Frames.FinalizeTranscript{}, :upstream)

    assert Harness.state(harness, :first) == [
             Frames.FinalizeTranscript,
             Frames.FinalizeTranscript
           ]

    assert Harness.outputs(harness) == [%Frames.FinalizeTranscript{id: 1}]
  end

  test "system frames overtake queued data frames" do
    harness =
      processor(:split, DataThenSystem)
      |> processor(:recorder, Recorder)
      |> Harness.run([%Frames.LLMText{text: "x"}])

    assert Harness.state(harness, :recorder) == [Frames.UserStartedSpeaking, Frames.Text]
  end

  test "async work streams frames back through its processor" do
    harness =
      processor(:llm, FakeLLM, words: ["a", "b"])
      |> Harness.run([%Frames.LLMContext{messages: []}])

    assert [
             %Frames.LLMResponseStart{},
             %Frames.LLMText{text: "a"},
             %Frames.LLMText{text: "b"},
             %Frames.LLMResponseEnd{}
           ] = Harness.outputs(harness)
  end

  describe "interruption" do
    setup do
      harness =
        processor(:context, Recorder)
        |> processor(:transcriber, Transcriber)
        |> processor(:llm, FakeLLM, words: ["a", "b"])
        |> Harness.start!(async: :manual)

      %{harness: harness}
    end

    test "kills in-flight work, and the partial reply goes upstream", %{harness: harness} do
      harness =
        harness
        |> Harness.push(%Frames.LLMContext{messages: []})
        |> Harness.push(%Frames.Interruption{})

      assert Harness.pending_tasks(harness) == []
      assert Harness.interrupted?(harness)
      assert Harness.outputs(harness, Frames.LLMText) == []
    end

    test "the interrupted processor's effects run", %{harness: harness} do
      # Let the reply stream one word, then interrupt.
      harness = Harness.push(harness, %Frames.LLMContext{messages: []})
      [{:llm, :reply}] = Harness.pending_tasks(harness)

      {[_start | _], core} =
        Core.async_message(harness.core, task_id(harness), {:text, "partial"})

      harness = Harness.push(%{harness | core: core}, %Frames.Interruption{})

      assert Frames.AssistantMessage in Harness.state(harness, :context)
    end

    test "tasks started for uninterruptible frames survive", %{harness: harness} do
      harness =
        harness
        |> Harness.push(%Frames.UserAudio{turn_id: 7, audio: <<>>})
        |> Harness.push(%Frames.Interruption{})

      assert Harness.pending_tasks(harness) == [{:transcriber, {:transcribe, 7}}]

      harness = Harness.run_tasks(harness)

      assert [%Frames.Transcription{turn_id: 7, text: "hello"}] =
               Harness.outputs(harness, Frames.Transcription)
    end

    test "results from killed tasks are dropped", %{harness: harness} do
      harness = Harness.push(harness, %Frames.LLMContext{messages: []})
      old_id = task_id(harness)
      harness = Harness.push(harness, %Frames.Interruption{})

      assert {[], _core} = Core.async_message(harness.core, old_id, {:text, "late"})
    end

    test "queued data frames are dropped, uninterruptible ones kept" do
      # The first stage pushes three frames; the interruption arrives while
      # the last two are still queued.
      defmodule Burst do
        use Octoroom.Agent.Processor

        @impl true
        def handle_frame(%Frames.LLMContext{}, :downstream, state) do
          {[
             {:push, %Frames.Text{text: "dropped"}, :downstream},
             {:push, %Frames.Transcription{text: "kept"}, :downstream},
             {:push, %Frames.Interruption{}, :downstream}
           ], state}
        end

        def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}
      end

      harness =
        processor(:burst, Burst)
        |> processor(:sink, Recorder)
        |> Harness.run([%Frames.LLMContext{}])

      assert [%Frames.Transcription{text: "kept"}] = Harness.outputs(harness)
      assert Harness.state(harness, :sink) == [Frames.Interruption, Frames.Transcription]
    end
  end

  test "timers fire through the harness and survive interruptions" do
    harness =
      processor(:turns, SilenceTimer)
      |> Harness.run([%Frames.VADUserStoppedSpeaking{}, %Frames.Interruption{}])

    assert Harness.timer_pending?(harness, :turns, :silence)

    harness = Harness.fire_timer(harness, :turns, :silence)
    assert [%Frames.UserStoppedSpeaking{turn_id: 1}] = Harness.outputs(harness)
  end

  test "a cancelled timer doesn't fire" do
    harness =
      processor(:turns, SilenceTimer)
      |> Harness.run([%Frames.VADUserStoppedSpeaking{}, %Frames.VADUserStartedSpeaking{}])

    refute Harness.timer_pending?(harness, :turns, :silence)
  end

  test "an exception becomes an Error frame that leaves upstream" do
    harness =
      processor(:recorder, Recorder)
      |> processor(:crash, Crash)
      |> Harness.run([%Frames.Text{text: "x"}])

    assert [{%RuntimeError{message: "boom"}, false}] = Harness.errors(harness)
    assert Harness.state(harness, :recorder) == [Frames.Text, Frames.Error]
  end

  test "handle_info messages reach the named stage" do
    harness =
      processor(:socket, Notifier)
      |> Harness.start!()
      |> Harness.info(:socket, {:socket, "hi"})

    assert Harness.notifications(harness) == [{:heard, "hi"}]
  end

  test "init gets a reply_to when the runner is a process" do
    defmodule CaptureCtx do
      use Octoroom.Agent.Processor

      @impl true
      def init(_opts, ctx), do: {:ok, ctx}
    end

    {:ok, core} = Core.new(processor(:a, CaptureCtx), %{runner: self()})
    assert %{name: :a, index: 0, reply_to: {pid, [:a]}} = Core.stage_state(core, :a)
    assert pid == self()

    Octoroom.Agent.Processor.send_to({pid, [:a]}, :ping)
    assert_received {:octoroom_agent_processor_info, [:a], :ping}
  end

  describe "UpdateStage" do
    defmodule Settable do
      use Octoroom.Agent.Processor

      @impl true
      def init(opts, _ctx), do: {:ok, Map.new(opts)}

      @impl true
      def handle_update(opts, state), do: {[], Map.merge(state, Map.new(opts))}
    end

    test "reaches the named stage's handle_update and goes no further" do
      harness =
        processor(:a, Recorder)
        |> processor(:b, Settable, voice: "old")
        |> processor(:c, Recorder)
        |> Harness.start!()
        |> Harness.push(%Frames.UpdateStage{stage: :b, opts: [voice: "new"]})

      assert Harness.state(harness, :b) == %{voice: "new"}
      # :a passed it on as a frame; :c never saw it.
      assert Harness.state(harness, :a) == [Frames.UpdateStage]
      assert Harness.state(harness, :c) == []
      assert Harness.outputs(harness) == []
    end

    test "travels upstream to the named stage too" do
      harness =
        processor(:b, Settable, voice: "old")
        |> processor(:c, Recorder)
        |> Harness.start!()
        |> Harness.push(%Frames.UpdateStage{stage: :b, opts: [voice: "new"]}, :upstream)

      assert Harness.state(harness, :b) == %{voice: "new"}
      assert Harness.upstream(harness) == []
    end

    test "naming no stage here, it leaves the pipeline" do
      update = %Frames.UpdateStage{stage: :elsewhere, opts: [voice: "new"]}

      harness =
        processor(:b, Settable)
        |> Harness.start!()
        |> Harness.push(update)

      assert [%Frames.UpdateStage{stage: :elsewhere}] = Harness.outputs(harness)
    end

    test "a stage without handle_update reports an error" do
      harness =
        processor(:a, Upcase)
        |> Harness.start!()
        |> Harness.push(%Frames.UpdateStage{stage: :a, opts: [voice: "new"]})

      assert Harness.errors(harness) == [{{:not_updatable, [:voice]}, false}]
      assert Harness.outputs(harness) == []
    end
  end

  defp task_id(harness) do
    [{id, _fun}] = harness.tasks
    id
  end
end
