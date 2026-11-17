defmodule Octoroom.Agent.VAD.SileroTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.VAD.Silero

  @frame_bytes 512 * 2

  test "reports low speech probability for silence" do
    {:ok, silero} = Silero.new()

    {probabilities, _silero} = Silero.process(silero, :binary.copy(<<0, 0>>, 16_000))

    assert length(probabilities) == 31
    assert Enum.all?(probabilities, &(&1 < 0.1))
  end

  test "buffers partial frames until enough audio arrives" do
    {:ok, silero} = Silero.new()

    assert {[], silero} = Silero.process(silero, :binary.copy(<<0>>, @frame_bytes - 2))
    assert byte_size(silero.buffer) == @frame_bytes - 2

    assert {[_probability], silero} = Silero.process(silero, <<0, 0, 0, 0>>)
    assert silero.buffer == <<0, 0>>
  end

  test "returns an error when the model file is missing" do
    assert {:error, {:silero_model_missing, "/nonexistent/silero.onnx"}} =
             Silero.new(model_path: "/nonexistent/silero.onnx")
  end

  test "reports a 32 ms frame duration" do
    assert Silero.frame_ms() == 32
  end
end
