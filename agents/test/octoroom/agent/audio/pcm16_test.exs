defmodule Octoroom.Agent.Audio.PCM16Test do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Audio.PCM16

  test "fades the first and last frames to zero" do
    audio = pcm16([10_000, 10_000, 10_000, 10_000, 10_000, 10_000])

    assert <<0::little-signed-16, second::little-signed-16, rest::binary>> =
             PCM16.fade_edges(audio, sample_rate: 1_000, channels: 1, duration_ms: 2)

    assert second == 5_000

    assert <<_third::little-signed-16, _fourth::little-signed-16, fifth::little-signed-16,
             0::little-signed-16>> = rest

    assert fifth == 5_000
  end

  test "leaves incomplete PCM frames unchanged" do
    assert <<1, 2, 3>> == PCM16.fade_edges(<<1, 2, 3>>)
  end

  defp pcm16(samples) do
    for sample <- samples, into: <<>>, do: <<sample::little-signed-16>>
  end
end
