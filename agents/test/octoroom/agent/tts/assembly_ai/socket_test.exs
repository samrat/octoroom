defmodule Octoroom.Agent.TTS.AssemblyAI.SocketTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.TTS.AssemblyAI
  alias Octoroom.Agent.TTS.AssemblyAI.Socket

  defp begun, do: %{Socket.initial_state(self()) | begun?: true}

  defp speak_entry(caller \\ self()),
    do: %{caller: caller, ref: make_ref(), monitor: Process.monitor(caller)}

  defp frame(map), do: {:text, Jason.encode!(map)}

  # What one callback result and the `:send_frames` messages after it put on
  # the wire.
  defp drain({:reply, {:text, json}, state}, frames) do
    receive do
      {:send_frames, rest} ->
        drain(Socket.handle_info({:send_frames, rest}, state), [json | frames])
    after
      0 -> {Enum.reverse([json | frames]) |> Enum.map(&Jason.decode!/1), state}
    end
  end

  defp drain({:ok, state}, frames),
    do: {Enum.reverse(frames) |> Enum.map(&Jason.decode!/1), state}

  test "a speak sends its text and a flush" do
    ref = make_ref()
    {frames, state} = drain(Socket.handle_cast({:speak, self(), ref, "Hello there"}, begun()), [])

    assert frames == [%{"type" => "Generate", "text" => "Hello there"}, %{"type" => "Flush"}]
    assert [%{ref: ^ref}] = state.speaks
  end

  test "frames before Begin wait for it" do
    state = Socket.initial_state(self())
    {:ok, state} = Socket.handle_cast({:speak, self(), make_ref(), "Hi"}, state)
    assert length(state.waiting) == 2

    {frames, state} = drain(Socket.handle_frame(frame(%{type: "Begin", id: "s"}), state), [])
    assert frames == [%{"type" => "Generate", "text" => "Hi"}, %{"type" => "Flush"}]
    assert state.waiting == [] and state.begun?
  end

  test "audio goes to the oldest speak until its FlushDone" do
    %{ref: first} = a = speak_entry()
    %{ref: second} = b = speak_entry()
    state = %{begun() | speaks: [a, b]}

    audio = frame(%{type: "Audio", audio: Base.encode64(<<1, 2>>), flush_id: 0})
    {:ok, state} = Socket.handle_frame(audio, state)
    assert_receive {^first, {:audio, <<1, 2>>}}

    {:ok, state} = Socket.handle_frame(frame(%{type: "FlushDone", flush_id: 0}), state)
    assert_receive {^first, :done}

    {:ok, state} = Socket.handle_frame(audio, state)
    assert_receive {^second, {:audio, <<1, 2>>}}
    assert [%{ref: ^second}] = state.speaks
  end

  test "a caller that dies cancels, and audio before Cancelled is dropped" do
    caller = spawn(fn -> Process.sleep(:infinity) end)
    %{monitor: monitor} = dying = speak_entry(caller)
    %{ref: other} = waiting = speak_entry()
    state = %{begun() | speaks: [dying, waiting]}

    {:reply, {:text, json}, state} =
      Socket.handle_info({:DOWN, monitor, :process, caller, :killed}, state)

    assert Jason.decode!(json) == %{"type" => "Cancel"}
    assert_receive {^other, {:error, :assembly_ai_speech_cancelled}}
    assert state.speaks == [] and state.cancels == 1

    %{ref: next} = after_cancel = speak_entry()
    state = %{state | speaks: [after_cancel]}
    audio = frame(%{type: "Audio", audio: Base.encode64(<<9>>), flush_id: 3})

    {:ok, state} = Socket.handle_frame(audio, state)
    refute_receive {^next, _}

    {:ok, state} = Socket.handle_frame(frame(%{type: "Cancelled"}), state)
    {:ok, _state} = Socket.handle_frame(audio, state)
    assert_receive {^next, {:audio, <<9>>}}
  end

  test "an Error fails the speaks in flight, and one not worth retrying stops reconnecting" do
    %{ref: ref} = entry = speak_entry()
    state = %{begun() | speaks: [entry]}

    error = %{type: "Error", error_code: 3012, error_type: "voice_not_found", retryable: false}
    {:ok, state} = Socket.handle_frame(frame(error), state)

    assert_receive {^ref, {:error, {:assembly_ai_speech_failed, %{"error_code" => 3012}}}}
    assert state.fatal?

    assert {:ok, _state} =
             Socket.handle_disconnect(%{reason: {:remote, 3012, ""}, attempt_number: 1}, state)
  end

  test "a dropped connection reconnects, and an idle timeout isn't fatal" do
    error = %{type: "Error", error_type: "inactivity_timeout", retryable: false}
    {:ok, state} = Socket.handle_frame(frame(error), begun())
    refute state.fatal?

    assert {:reconnect, %{begun?: false}} =
             Socket.handle_disconnect(%{reason: {:remote, 3006, ""}, attempt_number: 1}, state)
  end

  test "KeepAlive goes out only while idle" do
    assert {:reply, {:text, json}, state} = Socket.handle_info(:keep_alive, begun())
    assert Jason.decode!(json) == %{"type" => "KeepAlive"}
    Process.cancel_timer(state.keep_alive)

    busy = %{begun() | speaks: [speak_entry()]}
    assert {:ok, state} = Socket.handle_info(:keep_alive, busy)
    Process.cancel_timer(state.keep_alive)
  end

  test "text is split under 2,000 code points" do
    text = String.duplicate("é ", 1_500)
    parts = Socket.text_parts(text)

    assert Enum.join(parts) == text
    assert Enum.all?(parts, &(length(String.to_charlist(&1)) <= 2_000))
    assert length(parts) == 2
  end

  test "the connect query" do
    assert {:ok, query} =
             AssemblyAI.query(
               AssemblyAI.default_options() ++ [model: "assemblyai-tts-1", language: "english"]
             )

    assert query == %{
             voice_id: "aai-kyla",
             model_id: "assemblyai-tts-1",
             language: "english",
             sample_rate: 24_000,
             encoding: "pcm_s16le",
             word_boundaries: false
           }

    assert {:error, {:unsupported_sample_rate, 12_345, _}} = AssemblyAI.query(sample_rate: 12_345)
  end
end
