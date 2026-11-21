defmodule Octoroom.Agent.ModelsTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Models

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "octoroom_models_test_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "downloads, verifies sha256, and reuses cached file", %{dir: dir} do
    payload = "fake onnx weights"
    sha = :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
    parent = self()

    request_fun = fn url, opts ->
      send(parent, {:fetched, url})
      Enum.into([payload], Keyword.fetch!(opts, :into))
      {:ok, %{status: 200}}
    end

    assert {:ok, path} =
             Models.ensure(:smart_turn,
               models_dir: dir,
               url: "https://example.test/smart-turn.onnx",
               sha256: sha,
               request_fun: request_fun
             )

    assert_received {:fetched, "https://example.test/smart-turn.onnx"}
    assert File.read!(path) == payload
    assert Path.dirname(path) == dir

    # Second call uses cache without hitting request_fun.
    assert {:ok, ^path} =
             Models.ensure(:smart_turn,
               models_dir: dir,
               request_fun: fn _, _ -> flunk("should not download twice") end
             )
  end

  test "rejects checksum mismatch and removes temp file", %{dir: dir} do
    request_fun = fn _url, opts ->
      Enum.into(["corrupted"], Keyword.fetch!(opts, :into))
      {:ok, %{status: 200}}
    end

    expected = String.duplicate("0", 64)

    assert {:error, {:model_checksum_mismatch, :smart_turn, ^expected, actual}} =
             Models.ensure(:smart_turn,
               models_dir: dir,
               sha256: expected,
               request_fun: request_fun
             )

    assert actual != expected
    assert File.ls!(dir) == []
  end

  test "returns error on HTTP failure and leaves directory clean", %{dir: dir} do
    request_fun = fn _url, _opts -> {:ok, %{status: 404}} end

    assert {:error, {:model_download_failed, :smart_turn, 404}} =
             Models.ensure(:smart_turn, models_dir: dir, request_fun: request_fun)

    assert File.ls!(dir) == []
  end

  test "returns model_missing when download is disabled", %{dir: dir} do
    assert {:error, {:model_missing, :smart_turn, path}} =
             Models.ensure(:smart_turn, models_dir: dir, download: false)

    assert path == Path.join(dir, "smart-turn-v3.2-cpu.onnx")
  end
end
