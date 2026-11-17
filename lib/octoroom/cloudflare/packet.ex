defmodule Octoroom.Cloudflare.Packet do
  @moduledoc false

  # The WebSocket adapter's protobuf `Packet`: sequenceNumber (1, uint32),
  # timestamp (2, uint32), payload (5, bytes). Hand-rolled: three fields
  # don't justify a protobuf dependency. Unknown fields are skipped.

  import Bitwise

  @doc "Encodes a packet carrying only `payload`."
  def encode(payload) when is_binary(payload),
    do: <<0x2A>> <> varint(byte_size(payload)) <> payload

  @doc "Decodes a packet into a map with `:seq`, `:timestamp` and `:payload`."
  def decode(bin) do
    {:ok, decode(bin, %{})}
  rescue
    _ -> {:error, :invalid_packet}
  end

  defp decode(<<>>, acc), do: acc

  defp decode(bin, acc) do
    {key, rest} = read_varint(bin)

    case {key >>> 3, key &&& 7} do
      {field, 0} ->
        {value, rest} = read_varint(rest)
        decode(rest, put_field(acc, field, value))

      {field, 2} ->
        {len, rest} = read_varint(rest)
        <<value::binary-size(len), rest::binary>> = rest
        decode(rest, put_field(acc, field, value))

      {_field, 1} ->
        <<_::64, rest::binary>> = rest
        decode(rest, acc)

      {_field, 5} ->
        <<_::32, rest::binary>> = rest
        decode(rest, acc)
    end
  end

  defp put_field(acc, 1, value), do: Map.put(acc, :seq, value)
  defp put_field(acc, 2, value), do: Map.put(acc, :timestamp, value)
  defp put_field(acc, 5, value), do: Map.put(acc, :payload, value)
  defp put_field(acc, _field, _value), do: acc

  defp varint(n) when n < 128, do: <<n>>
  defp varint(n), do: <<(n &&& 0x7F) ||| 0x80>> <> varint(n >>> 7)

  defp read_varint(bin, shift \\ 0, acc \\ 0)

  defp read_varint(<<1::1, b::7, rest::binary>>, shift, acc),
    do: read_varint(rest, shift + 7, acc ||| b <<< shift)

  defp read_varint(<<0::1, b::7, rest::binary>>, shift, acc), do: {acc ||| b <<< shift, rest}
end
