defmodule Octoroom.Audio do
  @moduledoc """
  Conversions between Cloudflare's adapter PCM (48 kHz stereo s16le, 20 ms
  frames) and the format a worker asks for. Rates must divide 48 kHz
  (8, 12, 16, 24 or 48 kHz) and channels must be 1 or 2.
  """

  @adapter_rate 48_000
  # 20 ms at 48 kHz stereo s16le.
  @frame_bytes 3_840

  def adapter_rate, do: @adapter_rate
  def frame_bytes, do: @frame_bytes

  @doc "Raises unless `rate` and `channels` can be converted."
  def validate!(rate, channels) do
    unless is_integer(rate) and rate > 0 and rem(@adapter_rate, rate) == 0 and channels in [1, 2],
      do: raise(ArgumentError, "unsupported audio format: #{inspect({rate, channels})}")

    :ok
  end

  @doc """
  Adapter PCM to `rate`/`channels`. Each run of `48_000 / rate` frames is
  averaged into one, which also low-passes before decimating. Returns
  `{pcm, rest}`, where `rest` belongs in front of the next call's input.
  """
  def from_adapter(pcm, rate, channels) when is_binary(pcm) do
    validate!(rate, channels)
    factor = div(@adapter_rate, rate)
    group = factor * 4
    size = byte_size(pcm) - rem(byte_size(pcm), group)
    <<whole::binary-size(size), rest::binary>> = pcm

    out =
      if factor == 1 and channels == 2 do
        whole
      else
        for <<chunk::binary-size(group) <- whole>>, into: <<>> do
          {l, r} = sum_stereo(chunk, 0, 0)

          case channels do
            1 -> <<div(l + r, 2 * factor)::little-signed-16>>
            2 -> <<div(l, factor)::little-signed-16, div(r, factor)::little-signed-16>>
          end
        end
      end

    {out, rest}
  end

  defp sum_stereo(<<l::little-signed-16, r::little-signed-16, rest::binary>>, sl, sr),
    do: sum_stereo(rest, sl + l, sr + r)

  defp sum_stereo(<<>>, sl, sr), do: {sl, sr}

  @doc """
  PCM at `rate`/`channels` to adapter PCM, by linear interpolation. `prev` is
  the last frame of the previous call as `{left, right}` (`{0, 0}` to start);
  returns `{pcm, last_frame}`. A trailing partial frame is dropped.
  """
  def to_adapter(pcm, rate, channels, prev \\ {0, 0}) when is_binary(pcm) do
    validate!(rate, channels)
    factor = div(@adapter_rate, rate)

    frames =
      case channels do
        1 -> for <<s::little-signed-16 <- pcm>>, do: {s, s}
        2 -> for <<l::little-signed-16, r::little-signed-16 <- pcm>>, do: {l, r}
      end

    {out, last} =
      Enum.reduce(frames, {[], prev}, fn {l, r} = frame, {acc, {pl, pr}} ->
        samples =
          for i <- 1..factor do
            <<pl + div((l - pl) * i, factor)::little-signed-16,
              pr + div((r - pr) * i, factor)::little-signed-16>>
          end

        {[acc | samples], frame}
      end)

    {IO.iodata_to_binary(out), last}
  end
end
