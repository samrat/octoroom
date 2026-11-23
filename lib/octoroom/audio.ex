defmodule Octoroom.Audio do
  @moduledoc """
  Conversions between room PCM (48 kHz stereo s16le, Opus's own format, 20 ms
  frames) and the format a worker asks for. Rates must divide 48 kHz
  (8, 12, 16, 24 or 48 kHz) and channels must be 1 or 2.
  """

  @room_rate 48_000
  # 20 ms at 48 kHz stereo s16le.
  @frame_bytes 3_840

  def room_rate, do: @room_rate
  def frame_bytes, do: @frame_bytes

  @doc "Raises unless `rate` and `channels` can be converted."
  def validate!(rate, channels) do
    unless is_integer(rate) and rate > 0 and rem(@room_rate, rate) == 0 and channels in [1, 2],
      do: raise(ArgumentError, "unsupported audio format: #{inspect({rate, channels})}")

    :ok
  end

  @doc """
  Room PCM to `rate`/`channels`. Each run of `48_000 / rate` frames is
  averaged into one, which also low-passes before decimating. Returns
  `{pcm, rest}`, where `rest` belongs in front of the next call's input.
  """
  def from_room(pcm, rate, channels) when is_binary(pcm) do
    validate!(rate, channels)
    factor = div(@room_rate, rate)
    group = factor * 4
    size = byte_size(pcm) - rem(byte_size(pcm), group)
    <<whole::binary-size(^size), rest::binary>> = pcm

    out =
      if factor == 1 and channels == 2 do
        whole
      else
        for <<chunk::binary-size(^group) <- whole>>, into: <<>> do
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

  @doc "Converts s16le PCM between 1 and 2 channels (mono is copied to both; stereo is averaged)."
  def rechannel(pcm, same, same) when is_binary(pcm), do: pcm
  def rechannel(pcm, 1, 2), do: for(<<s::binary-size(2) <- pcm>>, into: <<>>, do: s <> s)

  def rechannel(pcm, 2, 1) do
    for <<l::little-signed-16, r::little-signed-16 <- pcm>>, into: <<>> do
      <<div(l + r, 2)::little-signed-16>>
    end
  end

  @doc """
  PCM at `rate`/`channels` to room PCM, by linear interpolation. `prev` is
  the last frame of the previous call as `{left, right}` (`{0, 0}` to start);
  returns `{pcm, last_frame}`. A trailing partial frame is dropped.
  """
  def to_room(pcm, rate, channels, prev \\ {0, 0}) when is_binary(pcm) do
    validate!(rate, channels)
    up(pcm, channels, div(@room_rate, rate), prev, <<>>)
  end

  # One input frame at a time, appending `factor` interpolated stereo frames
  # to a binary the runtime grows in place.
  defp up(<<s::little-signed-16, rest::binary>>, 1, factor, {pl, pr}, acc),
    do: up(rest, 1, factor, {s, s}, steps(acc, pl, pr, s, s, 1, factor))

  defp up(<<l::little-signed-16, r::little-signed-16, rest::binary>>, 2, factor, {pl, pr}, acc),
    do: up(rest, 2, factor, {l, r}, steps(acc, pl, pr, l, r, 1, factor))

  defp up(_partial, _channels, _factor, prev, acc), do: {acc, prev}

  defp steps(acc, _pl, _pr, l, r, factor, factor),
    do: <<acc::binary, l::little-signed-16, r::little-signed-16>>

  defp steps(acc, pl, pr, l, r, i, factor) do
    acc =
      <<acc::binary, pl + div((l - pl) * i, factor)::little-signed-16,
        pr + div((r - pr) * i, factor)::little-signed-16>>

    steps(acc, pl, pr, l, r, i + 1, factor)
  end
end
