defmodule Octoroom.Agent.Pipeline.SpecTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Pipeline.Spec

  defmodule A do
    use Octoroom.Agent.Processor
  end

  defmodule B do
    use Octoroom.Agent.Processor
  end

  test "builds a chain with |>" do
    spec =
      processor(:a, A, x: 1)
      |> processor(B)
      |> processor(:b2, B)
      |> processor(A, y: 2)

    assert names(spec) == [:a, B, :b2, A]
    assert [%{opts: [x: 1]}, %{opts: []}, %{opts: []}, %{opts: [y: 2]}] = spec.stages
  end

  test "rejects a name where a module belongs" do
    assert_raise ArgumentError, fn -> processor(:a, :b) end
    assert_raise ArgumentError, fn -> processor(:a, x: 1) end
  end

  test "edits stages by name" do
    spec = processor(:a, A) |> processor(:b, B)

    assert spec |> insert_after(:a, processor(:mid, B)) |> names() == [:a, :mid, :b]
    assert spec |> insert_before(:a, processor(:first, B)) |> names() == [:first, :a, :b]

    assert spec |> replace(:b, processor(:c, A) |> processor(:d, B)) |> names() ==
             [:a, :c, :d]

    assert spec |> remove(:a) |> names() == [:b]
    assert_raise ArgumentError, ~r/no stage named :zzz/, fn -> remove(spec, :zzz) end
  end

  test "validates names and modules" do
    assert {:ok, _spec} = Spec.validate(processor(:a, A))
    assert {:error, :empty_pipeline} = Spec.validate(Spec.new())

    assert {:error, {:duplicate_names, [:a]}} =
             Spec.validate(processor(:a, A) |> processor(:a, B))

    assert {:error, {:not_a_processor, :x, String}} =
             Spec.validate(processor(:a, A) |> processor(:x, String))
  end

  @stt "soniox:stt-rt-v6"
  @llm [provider: :google, model: "gemini-3.5-flash"]
  @tts [provider: :assembly_ai, model: "assemblyai-tts-1", voice: "aai-titus"]

  test "default builds a front end and a back end, each stage with its options" do
    {front, back} = default(stt: @stt, llm: @llm, tts: @tts)
    assert names(front) == [:vad, :stt, :turns]
    assert names(back) == [:context, :llm, :tools, :chunker, :tts, :collector]
    assert {:ok, _} = Spec.validate(front)
    assert {:ok, _} = Spec.validate(back)

    assert opts(front, :stt) == [model: "soniox:stt-rt-v6"]
    assert opts(front, :turns) == [vad: true, interrupt: false]
    assert opts(back, :llm) == @llm
    assert opts(back, :tts) == @tts
    assert opts(front, :nope) == nil

    {front, _back} = default(vad: false, stt: @stt, llm: @llm, tts: "inworld:inworld-tts-2")
    assert names(front) == [:stt, :turns]
    assert opts(front, :turns) == [vad: false, interrupt: false]
  end

  test "default picks no provider and no model" do
    assert_raise ArgumentError, ~r/stt: is needed/, fn -> default(llm: @llm, tts: @tts) end
    assert_raise ArgumentError, ~r/tts: is needed/, fn -> default(stt: @stt, llm: @llm) end
    assert_raise KeyError, fn -> default(stt: @stt, tts: @tts) end

    for stt <- ["soniox", :soniox, [provider: :soniox], "nobody:x"] do
      assert_raise ArgumentError, ~r/stt: needs a provider and a model/, fn ->
        default(stt: stt, llm: @llm, tts: @tts)
      end
    end

    assert_raise ArgumentError, ~r/tts: needs a provider and a model/, fn ->
      default(stt: @stt, llm: @llm, tts: [provider: :inworld, voice: "Ashley"])
    end

    for llm <- [[], [provider: :google], [model: "gemini-3.5-flash"]] do
      assert_raise ArgumentError, ~r/llm: needs a :provider and a :model/, fn ->
        default(stt: @stt, llm: llm, tts: @tts)
      end
    end

    assert_raise ArgumentError, fn -> default(stt: @stt, llm: @llm, tts: @tts, backend: %{}) end
  end

  test "default without speech-to-text records turns and transcribes them later" do
    half = [stt: false, llm: @llm, tts: @tts, transcriber: [model: "gemini-3.1-flash-lite"]]
    {front, back} = default(half ++ [vad: [min_speech_ms: 150]])

    assert names(front) == [:vad, :turns]
    assert List.last(front.stages).module == Octoroom.Agent.Processors.AudioTurns
    assert opts(front, :turns) == [interrupt: false, min_speech_ms: 150]
    assert names(back) == [:transcriber, :context, :llm, :tools, :chunker, :tts, :collector]
    assert opts(back, :transcriber) == [model: "gemini-3.1-flash-lite"]

    assert_raise ArgumentError, ~r/needs the VAD/, fn -> default(half ++ [vad: false]) end

    assert_raise ArgumentError, ~r/transcriber/, fn ->
      default(stt: false, llm: @llm, tts: @tts)
    end
  end

  test "gemini_live has no front end, and needs a model" do
    assert {nil, back} = gemini_live(model: "gemini-live-x", voice: "Puck")
    assert names(back) == [:gemini]
    assert opts(back, :gemini) == [model: "gemini-live-x", voice: "Puck"]
    assert_raise ArgumentError, fn -> gemini_live(voice: "Puck") end
  end
end
