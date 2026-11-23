defmodule Octoroom.Agent.NuanceLive.Protobuf do
  @moduledoc false

  # Minimal pure-Elixir Proto3 encoder/decoder for the LiveKit RTC signaling
  # (`livekit_rtc.proto`) and DataPacket (`livekit_models.proto`) subset used
  # by Nuance Live sessions. Zero protobuf codegen dependencies.

  import Bitwise

  @chunk_bytes 15_000

  # -- SignalRequest encoders --

  def encode_offer(sdp, id \\ 0) when is_binary(sdp) and is_integer(id),
    do: field_bytes(1, encode_sdp("offer", sdp, id))

  def encode_answer(sdp, id \\ 0) when is_binary(sdp) and is_integer(id),
    do: field_bytes(2, encode_sdp("answer", sdp, id))

  def encode_trickle(candidate_init, target, final \\ false)
      when is_binary(candidate_init) and target in [:publisher, :subscriber] do
    target_val = if target == :publisher, do: 0, else: 1

    body =
      IO.iodata_to_binary([
        field_bytes(1, candidate_init),
        if(target_val != 0, do: field_varint(2, target_val), else: <<>>),
        if(final, do: field_varint(3, 1), else: <<>>)
      ])

    field_bytes(3, body)
  end

  def encode_add_track(opts) when is_map(opts) do
    type_val =
      case Map.get(opts, :type, :audio) do
        :audio -> 0
        :video -> 1
        :data -> 2
      end

    source_val =
      case Map.get(opts, :source, :microphone) do
        :unknown -> 0
        :camera -> 1
        :microphone -> 2
        :screen_share -> 3
        :screen_share_audio -> 4
      end

    width = Map.get(opts, :width, 0)
    height = Map.get(opts, :height, 0)

    body =
      IO.iodata_to_binary([
        field_string(1, Map.get(opts, :cid, "")),
        field_string(2, Map.get(opts, :name, "")),
        if(type_val != 0, do: field_varint(3, type_val), else: <<>>),
        if(is_integer(width) and width > 0, do: field_varint(4, width), else: <<>>),
        if(is_integer(height) and height > 0, do: field_varint(5, height), else: <<>>),
        if(Map.get(opts, :muted, false), do: field_varint(6, 1), else: <<>>),
        if(source_val != 0, do: field_varint(8, source_val), else: <<>>),
        if(Map.get(opts, :disable_red, false), do: field_varint(13, 1), else: <<>>),
        field_string(15, Map.get(opts, :stream, ""))
      ])

    field_bytes(4, body)
  end

  def encode_leave(reason \\ 1) when is_integer(reason) do
    body =
      if reason == 0,
        do: <<>>,
        else: field_varint(2, reason)

    field_bytes(8, body)
  end

  def encode_ping(timestamp_ms, rtt \\ 0) when is_integer(timestamp_ms) and is_integer(rtt) do
    body =
      IO.iodata_to_binary([
        field_varint(1, timestamp_ms),
        if(rtt != 0, do: field_varint(2, rtt), else: <<>>)
      ])

    field_bytes(16, body)
  end

  defp encode_sdp(type, sdp, id) do
    IO.iodata_to_binary([
      field_string(1, type),
      field_string(2, sdp),
      if(id > 0, do: field_varint(3, id), else: <<>>)
    ])
  end

  # -- SignalResponse decoder --

  def decode_signal_response(bin) when is_binary(bin) do
    with {:ok, fields} <- decode_fields(bin) do
      {:ok, parse_signal_response(fields)}
    end
  end

  defp parse_signal_response(fields) do
    case fields do
      [{1, {:bytes, data}} | _] -> {:join, decode_join_response(data)}
      [{2, {:bytes, data}} | _] -> {:answer, decode_sdp(data)}
      [{3, {:bytes, data}} | _] -> {:offer, decode_sdp(data)}
      [{4, {:bytes, data}} | _] -> {:trickle, decode_trickle(data)}
      [{6, {:bytes, data}} | _] -> {:track_published, decode_track_published(data)}
      [{8, {:bytes, data}} | _] -> {:leave, decode_leave(data)}
      [{16, {:bytes, token}} | _] -> {:refresh_token, token}
      [{18, {:varint, ts}} | _] -> {:pong, ts}
      [{20, {:bytes, data}} | _] -> {:pong_resp, decode_pong(data)}
      [{21, {:bytes, data}} | _] -> {:subscription_response, decode_subscription_response(data)}
      [{field, _} | _] -> {:other, field}
      [] -> {:other, 0}
    end
  end

  defp decode_join_response(bin) do
    fields = decode_fields!(bin)

    ice_servers =
      for {5, {:bytes, data}} <- fields do
        decode_ice_server(data)
      end

    %{
      ice_servers: ice_servers,
      subscriber_primary: get_bool(fields, 6, false),
      ping_timeout: get_int(fields, 10, 0),
      ping_interval: get_int(fields, 11, 0),
      fast_publish: get_bool(fields, 15, false)
    }
  end

  defp decode_ice_server(bin) do
    fields = decode_fields!(bin)
    urls = for {1, {:bytes, url}} <- fields, do: url
    username = get_string(fields, 2, nil)
    credential = get_string(fields, 3, nil)

    %{urls: urls}
    |> then(fn m ->
      if username && username != "", do: Map.put(m, :username, username), else: m
    end)
    |> then(fn m ->
      if credential && credential != "", do: Map.put(m, :credential, credential), else: m
    end)
  end

  defp decode_sdp(bin) do
    fields = decode_fields!(bin)

    %{
      type: get_string(fields, 1, ""),
      sdp: get_string(fields, 2, ""),
      id: get_int(fields, 3, 0)
    }
  end

  defp decode_trickle(bin) do
    fields = decode_fields!(bin)

    target =
      case get_int(fields, 2, 0) do
        1 -> :subscriber
        _ -> :publisher
      end

    %{
      candidate_init: get_string(fields, 1, ""),
      target: target,
      final: get_bool(fields, 3, false)
    }
  end

  defp decode_track_published(bin) do
    fields = decode_fields!(bin)
    cid = get_string(fields, 1, "")

    sid =
      case List.keyfind(fields, 2, 0) do
        {2, {:bytes, info_bin}} -> get_string(decode_fields!(info_bin), 1, "")
        _ -> ""
      end

    %{cid: cid, sid: sid}
  end

  defp decode_leave(bin) do
    fields = decode_fields!(bin)

    %{
      can_reconnect: get_bool(fields, 1, false),
      reason: get_int(fields, 2, 0),
      action: get_int(fields, 3, 0)
    }
  end

  defp decode_pong(bin) do
    fields = decode_fields!(bin)

    %{
      last_ping_timestamp: get_int(fields, 1, 0),
      timestamp: get_int(fields, 2, 0)
    }
  end

  defp decode_subscription_response(bin) do
    fields = decode_fields!(bin)

    %{
      track_sid: get_string(fields, 1, ""),
      err: get_int(fields, 2, 0)
    }
  end

  # -- DataPacket encoders & decoder --

  def encode_user_packet(payload, topic, opts \\ [])
      when is_binary(payload) and is_binary(topic) do
    kind = Keyword.get(opts, :kind, :reliable)
    kind_val = if kind == :lossy, do: 1, else: 0
    seq = Keyword.get(opts, :sequence)

    user =
      IO.iodata_to_binary([
        field_bytes(2, payload),
        field_string(4, topic)
      ])

    IO.iodata_to_binary([
      if(kind_val != 0, do: field_varint(1, kind_val), else: <<>>),
      field_bytes(2, user),
      if(is_integer(seq) and seq > 0, do: field_varint(16, seq), else: <<>>)
    ])
  end

  @doc """
  Encodes a UTF-8 string as a LiveKit DataStream text stream (`Header`,
  `Chunk`s, `Trailer`) wrapped in reliable `DataPacket` binaries.
  """
  def encode_text_stream(text, topic, stream_id, opts \\ [])
      when is_binary(text) and is_binary(topic) and is_binary(stream_id) do
    ts = Keyword.get(opts, :timestamp, System.system_time(:millisecond))
    total = byte_size(text)
    # TextHeader with operation_type = CREATE (0) is an empty embedded message.
    header_body =
      IO.iodata_to_binary([
        field_string(1, stream_id),
        if(ts > 0, do: field_varint(2, ts), else: <<>>),
        field_string(3, topic),
        field_string(4, "text/plain"),
        field_varint(5, total),
        field_bytes(9, <<>>)
      ])

    header_pkt = field_bytes(13, header_body)

    chunk_pkts =
      text
      |> split_chunks(@chunk_bytes, 0, [])
      |> Enum.map(fn {idx, chunk} ->
        body =
          IO.iodata_to_binary([
            field_string(1, stream_id),
            if(idx > 0, do: field_varint(2, idx), else: <<>>),
            field_bytes(3, chunk)
          ])

        field_bytes(14, body)
      end)

    trailer_pkt = field_bytes(15, field_string(1, stream_id))

    [header_pkt | chunk_pkts] ++ [trailer_pkt]
  end

  defp split_chunks(<<>>, _size, _idx, acc), do: Enum.reverse(acc)

  defp split_chunks(bin, size, idx, acc) when byte_size(bin) <= size do
    Enum.reverse([{idx, bin} | acc])
  end

  defp split_chunks(bin, size, idx, acc) do
    <<chunk::binary-size(^size), rest::binary>> = bin
    split_chunks(rest, size, idx + 1, [{idx, chunk} | acc])
  end

  def decode_data_packet(bin) when is_binary(bin) do
    with {:ok, fields} <- decode_fields(bin) do
      identity = get_string(fields, 4, nil)

      cond do
        match?({2, {:bytes, _}}, List.keyfind(fields, 2, 0)) ->
          {2, {:bytes, user_bin}} = List.keyfind(fields, 2, 0)

          with {:ok, user_fields} <- decode_fields(user_bin) do
            {:ok,
             {:user,
              %{
                payload: get_string(user_fields, 2, <<>>),
                topic: get_string(user_fields, 4, nil),
                participant_identity: identity || get_string(user_fields, 5, nil)
              }}}
          end

        match?({13, {:bytes, _}}, List.keyfind(fields, 13, 0)) ->
          {13, {:bytes, header_bin}} = List.keyfind(fields, 13, 0)

          with {:ok, hfields} <- decode_fields(header_bin) do
            {:ok,
             {:stream_header,
              %{
                stream_id: get_string(hfields, 1, ""),
                topic: get_string(hfields, 3, nil),
                inline_content: get_string(hfields, 11, nil),
                participant_identity: identity
              }}}
          end

        match?({14, {:bytes, _}}, List.keyfind(fields, 14, 0)) ->
          {14, {:bytes, chunk_bin}} = List.keyfind(fields, 14, 0)

          with {:ok, cfields} <- decode_fields(chunk_bin) do
            {:ok,
             {:stream_chunk,
              %{
                stream_id: get_string(cfields, 1, ""),
                chunk_index: get_int(cfields, 2, 0),
                content: get_string(cfields, 3, <<>>)
              }}}
          end

        match?({15, {:bytes, _}}, List.keyfind(fields, 15, 0)) ->
          {15, {:bytes, trailer_bin}} = List.keyfind(fields, 15, 0)

          with {:ok, tfields} <- decode_fields(trailer_bin) do
            {:ok,
             {:stream_trailer,
              %{
                stream_id: get_string(tfields, 1, ""),
                reason: get_string(tfields, 2, "")
              }}}
          end

        true ->
          {:ok, {:other, fields}}
      end
    end
  end

  # -- Low-level Proto3 wire primitives --

  defp field_varint(num, val) when is_integer(val) and val >= 0,
    do: IO.iodata_to_binary([encode_varint(num <<< 3 ||| 0), encode_varint(val)])

  defp field_string(_num, ""), do: <<>>
  defp field_string(num, str) when is_binary(str), do: field_bytes(num, str)

  defp field_bytes(num, data) when is_binary(data),
    do:
      IO.iodata_to_binary([encode_varint(num <<< 3 ||| 2), encode_varint(byte_size(data)), data])

  defp encode_varint(n) when n < 128, do: <<n>>

  defp encode_varint(n),
    do: <<1::1, band(n, 0x7F)::7, encode_varint(n >>> 7)::binary>>

  defp decode_fields(bin), do: do_decode_fields(bin, [])

  defp decode_fields!(bin) do
    case decode_fields(bin) do
      {:ok, fields} -> fields
      {:error, _} -> []
    end
  end

  defp do_decode_fields(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp do_decode_fields(bin, acc) do
    with {:ok, tag, rest} <- decode_varint(bin),
         field = tag >>> 3,
         wire = band(tag, 0x07),
         {:ok, value, rest} <- decode_wire_value(wire, rest) do
      do_decode_fields(rest, [{field, value} | acc])
    end
  end

  defp decode_wire_value(0, bin) do
    with {:ok, val, rest} <- decode_varint(bin), do: {:ok, {:varint, val}, rest}
  end

  defp decode_wire_value(1, <<val::little-unsigned-64, rest::binary>>),
    do: {:ok, {:fixed64, val}, rest}

  defp decode_wire_value(2, bin) do
    with {:ok, len, rest} <- decode_varint(bin),
         true <- byte_size(rest) >= len do
      <<data::binary-size(^len), tail::binary>> = rest
      {:ok, {:bytes, data}, tail}
    else
      false -> {:error, :truncated_bytes}
      error -> error
    end
  end

  defp decode_wire_value(5, <<val::little-unsigned-32, rest::binary>>),
    do: {:ok, {:fixed32, val}, rest}

  defp decode_wire_value(wire, _bin), do: {:error, {:unsupported_wire_type, wire}}

  defp decode_varint(bin), do: do_decode_varint(bin, 0, 0)

  defp do_decode_varint(<<1::1, byte::7, rest::binary>>, shift, acc) when shift < 64,
    do: do_decode_varint(rest, shift + 7, acc ||| byte <<< shift)

  defp do_decode_varint(<<0::1, byte::7, rest::binary>>, shift, acc) when shift < 64,
    do: {:ok, acc ||| byte <<< shift, rest}

  defp do_decode_varint(_, _, _), do: {:error, :invalid_varint}

  defp get_string(fields, num, default) do
    case List.keyfind(fields, num, 0) do
      {^num, {:bytes, val}} -> val
      _ -> default
    end
  end

  defp get_int(fields, num, default) do
    case List.keyfind(fields, num, 0) do
      {^num, {:varint, val}} -> val
      _ -> default
    end
  end

  defp get_bool(fields, num, default) do
    case List.keyfind(fields, num, 0) do
      {^num, {:varint, val}} -> val != 0
      _ -> default
    end
  end
end
