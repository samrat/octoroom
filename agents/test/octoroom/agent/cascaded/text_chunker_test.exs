defmodule Octoroom.Agent.Cascaded.TextChunkerTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Cascaded.TextChunker

  test "waits for a speakable sentence boundary" do
    state = TextChunker.new()

    assert {[], state} = TextChunker.push(state, "This is")
    assert {["This is ready."], state} = TextChunker.push(state, " ready. Next")
    assert {["Next"], _state} = TextChunker.flush(state)
  end

  test "uses clause boundaries after enough words" do
    text = "We can start with the first useful clause, and keep going"

    assert {["We can start with the first useful clause,"], state} =
             TextChunker.push(TextChunker.new(), text)

    assert {["and keep going"], _state} = TextChunker.flush(state)
  end

  test "falls back to a word limit without punctuation" do
    text = Enum.map_join(1..26, " ", &"word#{&1}")

    assert {[chunk], state} = TextChunker.push(TextChunker.new(), text)
    assert length(String.split(chunk)) == 24
    assert {["word25 word26"], _state} = TextChunker.flush(state)
  end

  test "after the first chunk, waits for a sentence boundary instead of a clause" do
    {[first], state} = TextChunker.push(TextChunker.new(), "Sure thing, happy to. ")
    assert first == "Sure thing, happy to."

    text = "We can start with the first useful clause, and keep going"
    assert {[], state} = TextChunker.push(state, text)
    assert {[chunk], _state} = TextChunker.push(state, " until the end.")
    assert chunk == text <> " until the end."
  end

  test "after the first chunk, splits run-on text at a clause near the word limit" do
    {[_first], state} = TextChunker.push(TextChunker.new(), "Okay, here it is. ")
    clause = Enum.map_join(1..30, " ", &"word#{&1}") <> ","
    rest = Enum.map_join(31..65, " ", &"word#{&1}")

    assert {[^clause], state} = TextChunker.push(state, clause <> " " <> rest)
    assert {[^rest], _state} = TextChunker.flush(state)
  end
end
