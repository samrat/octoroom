defmodule Octoroom.Agent.Audio.MixerTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Audio.Mixer

  # `ms` of 16 kHz mono at one sample value.
  defp pcm(ms, value), do: :binary.copy(<<value::signed-little-16>>, 16 * ms)

  defp samples(pcm), do: for(<<s::signed-little-16 <- pcm>>, uniq: true, do: s)

  test "an input is mixed once it has two chunks, and stops when it runs dry" do
    mixer = Mixer.new() |> Mixer.push("a", pcm(20, 5))
    assert {nil, mixer} = Mixer.pull(mixer)

    mixer = Mixer.push(mixer, "a", pcm(20, 5))
    assert {chunk, mixer} = Mixer.pull(mixer)
    assert byte_size(chunk) == 640 and samples(chunk) == [5]
    assert {chunk, mixer} = Mixer.pull(mixer)
    assert samples(chunk) == [5]
    assert {nil, _mixer} = Mixer.pull(mixer)
  end

  test "sums inputs, clamping, and pads one that's short" do
    mixer =
      Mixer.new()
      |> Mixer.push("a", pcm(40, 30_000))
      |> Mixer.push("b", pcm(40, 10_000))
      |> Mixer.push("c", pcm(40, -3))

    assert {chunk, mixer} = Mixer.pull(mixer)
    assert samples(chunk) == [32_767]

    mixer = mixer |> Mixer.drop("a") |> Mixer.drop("b")
    # c has 20 ms left; then 10 ms of it and 10 ms of silence.
    mixer = Mixer.push(mixer, "c", pcm(10, -3))
    assert {chunk, mixer} = Mixer.pull(mixer)
    assert samples(chunk) == [-3]
    assert {chunk, _mixer} = Mixer.pull(mixer)
    assert samples(binary_part(chunk, 0, 320)) == [-3]
    assert samples(binary_part(chunk, 320, 320)) == [0]
  end

  test "keeps at most max_ms of an input, dropping the oldest" do
    mixer = Mixer.new(max_ms: 40) |> Mixer.push("a", pcm(40, 1)) |> Mixer.push("a", pcm(40, 2))
    assert {chunk, mixer} = Mixer.pull(mixer)
    assert samples(chunk) == [2]
    assert {chunk, mixer} = Mixer.pull(mixer)
    assert samples(chunk) == [2]
    assert {nil, _} = Mixer.pull(mixer)
  end
end
