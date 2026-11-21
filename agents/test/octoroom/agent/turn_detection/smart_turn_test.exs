defmodule Octoroom.Agent.TurnDetection.SmartTurnTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.TurnDetection.SmartTurn

  test "returns an error when an explicit model_path is missing" do
    assert {:error, {:smart_turn_model_missing, "/nonexistent/smart-turn.onnx"}} =
             SmartTurn.new(model_path: "/nonexistent/smart-turn.onnx")
  end

  test "returns model_missing when download is disabled and cache is empty" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "octoroom_smart_turn_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)

    assert {:error, {:model_missing, :smart_turn, path}} =
             SmartTurn.new(models_dir: dir, download: false)

    assert path == Path.join(dir, "smart-turn-v3.2-cpu.onnx")
  end

  test "buffers up to 8 seconds of audio and supports trimming and reset" do
    st = %SmartTurn{}
    one_sec = :binary.copy(<<1, 0>>, 16_000)

    st = Enum.reduce(1..10, st, fn _, acc -> SmartTurn.append(acc, one_sec) end)
    assert SmartTurn.buffered_ms(st) == 8_000

    st = SmartTurn.keep_last_ms(st, 500)
    assert SmartTurn.buffered_ms(st) == 500

    st = SmartTurn.reset(st)
    assert SmartTurn.buffered_ms(st) == 0
  end
end
