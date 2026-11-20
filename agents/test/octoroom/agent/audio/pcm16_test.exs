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

  test "resamples 16 kHz to 24 kHz continuously across chunk boundaries" do
    samples = [0, 300, 600, 900, 1200, 1500]
    whole = PCM16.resample(pcm16(samples), 16_000, 24_000)
    assert byte_size(whole) == 9 * 2

    {chunk1, state} = PCM16.resample_stream(pcm16([0, 300, 600]), 16_000, 24_000, nil)
    {chunk2, _state} = PCM16.resample_stream(pcm16([900, 1200, 1500]), 16_000, 24_000, state)
    assert chunk1 <> chunk2 == whole

    # 20 ms at 16 kHz (320 samples = 640 bytes) -> 20 ms at 24 kHz (480 samples = 960 bytes).
    frame_16k = :binary.copy(<<100::little-signed-16>>, 320)
    assert byte_size(PCM16.resample(frame_16k, 16_000, 24_000)) == 960
  end

  test "resamples 24 kHz to 16 kHz and handles same-rate no-op" do
    samples = [0, 200, 400, 600, 800, 1000]
    out = PCM16.resample(pcm16(samples), 24_000, 16_000)
    assert for(<<s::little-signed-16 <- out>>, do: s) == [0, 300, 600, 900]

    raw = pcm16([1, 2, 3])
    assert {^raw, :st} = PCM16.resample_stream(raw, 24_000, 24_000, :st)
  end

  defp pcm16(samples) do
    for sample <- samples, into: <<>>, do: <<sample::little-signed-16>>
  end
end
