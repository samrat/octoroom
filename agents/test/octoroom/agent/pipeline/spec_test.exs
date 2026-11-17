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

  test "cascaded builds the default chain" do
    spec = cascaded(Octoroom.Agent.Backend.Cascaded.new())

    assert names(spec) == [:vad, :stt, :turns, :context, :llm, :tools, :chunker, :tts, :collector]
    assert {:ok, _spec} = Spec.validate(spec)
  end

  test "cascaded refuses stages that aren't copied yet" do
    assert_raise ArgumentError, fn ->
      cascaded(Octoroom.Agent.Backend.Cascaded.new(%{turn_detection: :smart_turn}))
    end
  end

  test "cascaded_split builds both pipelines, with an optional decision stage" do
    {front, back} = cascaded_split(Octoroom.Agent.Backend.Cascaded.new())
    assert names(front) == [:vad, :stt, :turns]
    assert names(back) == [:context, :llm, :tools, :chunker, :tts, :collector]

    {front, back} =
      cascaded_split(Octoroom.Agent.Backend.Cascaded.new(%{stt: false}), decisions: [])

    assert names(front) == [:vad, :turns, :decisions]
    assert hd(front.stages |> tl()).module == Octoroom.Agent.Processors.AudioTurns
    assert names(back) == [:transcriber, :context, :llm, :tools, :chunker, :tts, :collector]
    assert {:ok, _} = Spec.validate(front)
  end
end
