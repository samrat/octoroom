defmodule Octoroom.Agent.TTS.TinyVoca.G2P do
  @moduledoc false

  # Unknown-word grapheme-to-phoneme model (`phonemizer/g2p.npz` + `g2p.json`).
  #
  # Converts the NumPy `.npz` weights into a small ONNX graph (embedding lookup +
  # slot addition + 2-layer bidirectional GRU + linear head + argmax) cached right
  # next to `g2p.npz` as `g2p.onnx`, then runs inference natively via OnnxRuntime.

  import Bitwise

  defstruct [:model, :letters, :symbols]

  @doc """
  Loads the G2P model from `phonemizer_dir` (containing `g2p.json` and `g2p.npz`),
  emitting `g2p.onnx` once if not already present.
  """
  def load(phonemizer_dir) do
    json_path = Path.join(phonemizer_dir, "g2p.json")
    npz_path = Path.join(phonemizer_dir, "g2p.npz")
    onnx_path = Path.join(phonemizer_dir, "g2p.onnx")

    settings = json_path |> File.read!() |> Jason.decode!()

    unless File.regular?(onnx_path) do
      weights = read_npz!(npz_path)
      onnx_bin = build_onnx(settings, weights)
      tmp = "#{onnx_path}.tmp.#{System.unique_integer([:positive])}"
      File.write!(tmp, onnx_bin)
      File.rename!(tmp, onnx_path)
    end

    model = OnnxRuntime.load(onnx_path)

    letters =
      settings["letters"]
      |> String.graphemes()
      |> Enum.with_index(1)
      |> Map.new()

    %__MODULE__{
      model: model,
      letters: letters,
      symbols: List.to_tuple(settings["symbols"])
    }
  end

  @doc "Reduces `word` to the lowercase ASCII letters and apostrophes the model knows."
  def spellable(%__MODULE__{letters: letters}, word) when is_binary(word) do
    word
    |> String.downcase()
    |> :unicode.characters_to_nfkd_binary()
    |> String.graphemes()
    |> Enum.filter(&Map.has_key?(letters, &1))
    |> Enum.join()
    |> String.trim("'")
  end

  @doc "Predicts CMUdict ARPAbet symbols (with stress digits) for an OOV word."
  def predict(%__MODULE__{} = g2p, word) when is_binary(word) do
    word = spellable(g2p, word)

    if word == "" do
      []
    else
      ids = word |> String.graphemes() |> Enum.map(&Map.fetch!(g2p.letters, &1))
      input = Nx.tensor(ids, type: :s64)
      {labels_tensor} = OnnxRuntime.run(g2p.model, {input})

      labels =
        labels_tensor
        |> Nx.backend_transfer(Nx.BinaryBackend)
        |> Nx.to_flat_list()

      ctc_decode(labels, 0, g2p.symbols, [])
    end
  end

  defp ctc_decode([], _prev, _symbols, acc), do: Enum.reverse(acc)

  defp ctc_decode([label | rest], prev, symbols, acc) do
    acc =
      if label != prev and label != 0,
        do: [elem(symbols, label - 1) | acc],
        else: acc

    ctc_decode(rest, label, symbols, acc)
  end

  # -- .npz / .npy reader

  @doc false
  def read_npz!(path) do
    {:ok, entries} = :zip.unzip(String.to_charlist(path), [:memory])

    Map.new(entries, fn {name_charlist, bin} ->
      name = name_charlist |> List.to_string() |> String.replace_suffix(".npy", "")
      {name, parse_npy!(bin)}
    end)
  end

  defp parse_npy!(<<0x93, "NUMPY", major, _minor, rest::binary>>) do
    {header_len, data} =
      case major do
        1 ->
          <<len::little-unsigned-16, body::binary>> = rest
          {len, body}

        _ ->
          <<len::little-unsigned-32, body::binary>> = rest
          {len, body}
      end

    <<header::binary-size(header_len), raw::binary>> = data
    shape = parse_npy_shape!(header)
    %{shape: shape, raw: raw}
  end

  defp parse_npy_shape!(header) do
    [_, dims_str] = Regex.run(~r/'shape':\s*\(([^)]*)\)/, header)

    dims_str
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.to_integer()))
  end

  # -- ONNX protobuf builder (IR v8, opset 17)
  #
  # Matches `dizione/g2p.py` (`convs == 0`, 2-layer bidirectional GRU + linear head):
  #   letter_ids [N] s64
  #     -> Gather(embed__weight) [N, W]
  #     -> Unsqueeze(axis=1) [N, 1, W]
  #     -> Add(slot) [N, slots, W]
  #     -> Reshape([-1, 1, W]) [N*slots, 1, W]
  #     -> for each GRU layer l:
  #          GRU(direction="bidirectional", hidden_size=H, linear_before_reset=1) -> [T, 2, 1, H]
  #          Transpose([0, 2, 1, 3]) -> [T, 1, 2, H]
  #          Reshape([-1, 1, 2*H])
  #     -> Reshape([-1, 2*H])
  #     -> Gemm(out__weight, out__bias, transB=1) -> [T, num_classes]
  #     -> ArgMax(axis=1, keepdims=0) -> labels [T] s64

  @doc false
  def build_onnx(settings, weights) do
    if Map.get(settings, "convs", 0) != 0 do
      raise ArgumentError, "unsupported g2p convs=#{inspect(settings["convs"])}"
    end

    width = settings["width"]
    hidden = settings["hidden"]
    layers = settings["layers"]
    %{shape: [embed_rows, _]} = weights["embed__weight"]
    %{shape: [slots, _]} = weights["slot"]
    %{shape: [num_classes, out_in]} = weights["out__weight"]

    init_nodes = [
      node_proto("Gather", ["embed_weight", "letter_ids"], ["emb"]),
      node_proto("Unsqueeze", ["emb", "axis_1"], ["emb_u"]),
      node_proto("Add", ["emb_u", "slot"], ["emb_slot"]),
      node_proto("Reshape", ["emb_slot", "shape_in"], ["x0"])
    ]

    init_tensors = [
      tensor_proto("embed_weight", [embed_rows, width], 1, weights["embed__weight"].raw),
      tensor_proto("slot", [1, slots, width], 1, weights["slot"].raw),
      tensor_proto("axis_1", [1], 7, <<1::little-signed-64>>),
      tensor_proto(
        "shape_in",
        [3],
        7,
        <<-1::little-signed-64, 1::little-signed-64, width::little-signed-64>>
      ),
      tensor_proto(
        "shape_gru_out",
        [3],
        7,
        <<-1::little-signed-64, 1::little-signed-64, 2 * hidden::little-signed-64>>
      ),
      tensor_proto("shape_flat", [2], 7, <<-1::little-signed-64, out_in::little-signed-64>>),
      tensor_proto("out_weight", [num_classes, out_in], 1, weights["out__weight"].raw),
      tensor_proto("out_bias", [num_classes], 1, weights["out__bias"].raw)
    ]

    {gru_nodes, gru_tensors, last_x} =
      Enum.reduce(0..(layers - 1), {[], [], "x0"}, fn layer, {ns, ts, x_in} ->
        in_size = if layer == 0, do: width, else: 2 * hidden
        {w_bin, r_bin, b_bin} = pack_gru_layer(weights, layer, hidden, in_size)

        w_name = "gru_w_#{layer}"
        r_name = "gru_r_#{layer}"
        b_name = "gru_b_#{layer}"
        y_raw = "gru_y_#{layer}"
        y_t = "gru_yt_#{layer}"
        y_out = "x#{layer + 1}"

        layer_nodes = [
          node_proto("GRU", [x_in, w_name, r_name, b_name], [y_raw], [
            attr_string("direction", "bidirectional"),
            attr_int("hidden_size", hidden),
            attr_int("linear_before_reset", 1)
          ]),
          node_proto("Transpose", [y_raw], [y_t], [attr_ints("perm", [0, 2, 1, 3])]),
          node_proto("Reshape", [y_t, "shape_gru_out"], [y_out])
        ]

        layer_tensors = [
          tensor_proto(w_name, [2, 3 * hidden, in_size], 1, w_bin),
          tensor_proto(r_name, [2, 3 * hidden, hidden], 1, r_bin),
          tensor_proto(b_name, [2, 6 * hidden], 1, b_bin)
        ]

        {ns ++ layer_nodes, ts ++ layer_tensors, y_out}
      end)

    head_nodes = [
      node_proto("Reshape", [last_x, "shape_flat"], ["x_flat"]),
      node_proto("Gemm", ["x_flat", "out_weight", "out_bias"], ["logits"], [attr_int("transB", 1)]),
      node_proto("ArgMax", ["logits"], ["labels"], [attr_int("axis", 1), attr_int("keepdims", 0)])
    ]

    graph =
      graph_proto(
        "dizione_g2p",
        init_nodes ++ gru_nodes ++ head_nodes,
        init_tensors ++ gru_tensors,
        [value_info_proto("letter_ids", 7, ["N"])],
        [value_info_proto("labels", 7, ["T"])]
      )

    model_proto(8, 17, graph)
  end

  # Reorders PyTorch GRU gate rows from (r, z, n) to ONNX (z, r, h).
  defp pack_gru_layer(weights, layer, hidden, in_size) do
    w_fwd = reorder_gates(weights["gru__weight_ih_l#{layer}"].raw, hidden, in_size)
    w_rev = reorder_gates(weights["gru__weight_ih_l#{layer}_reverse"].raw, hidden, in_size)

    r_fwd = reorder_gates(weights["gru__weight_hh_l#{layer}"].raw, hidden, hidden)
    r_rev = reorder_gates(weights["gru__weight_hh_l#{layer}_reverse"].raw, hidden, hidden)

    b_ih_fwd = reorder_gates(weights["gru__bias_ih_l#{layer}"].raw, hidden, 1)
    b_hh_fwd = reorder_gates(weights["gru__bias_hh_l#{layer}"].raw, hidden, 1)
    b_ih_rev = reorder_gates(weights["gru__bias_ih_l#{layer}_reverse"].raw, hidden, 1)
    b_hh_rev = reorder_gates(weights["gru__bias_hh_l#{layer}_reverse"].raw, hidden, 1)

    {w_fwd <> w_rev, r_fwd <> r_rev, b_ih_fwd <> b_hh_fwd <> b_ih_rev <> b_hh_rev}
  end

  defp reorder_gates(bin, hidden, cols) do
    chunk_bytes = hidden * cols * 4

    <<r::binary-size(chunk_bytes), z::binary-size(chunk_bytes), n::binary-size(chunk_bytes)>> =
      bin

    z <> r <> n
  end

  # -- Minimal Protobuf wire encoder

  defp model_proto(ir_version, opset_version, graph_bin) do
    opset = IO.iodata_to_binary([field_bytes(1, ""), field_varint(2, opset_version)])

    IO.iodata_to_binary([
      field_varint(1, ir_version),
      field_bytes(7, graph_bin),
      field_bytes(8, opset)
    ])
  end

  defp graph_proto(name, nodes, initializers, inputs, outputs) do
    IO.iodata_to_binary([
      Enum.map(nodes, &field_bytes(1, &1)),
      field_bytes(2, name),
      Enum.map(initializers, &field_bytes(5, &1)),
      Enum.map(inputs, &field_bytes(11, &1)),
      Enum.map(outputs, &field_bytes(12, &1))
    ])
  end

  defp node_proto(op_type, inputs, outputs, attrs \\ []) do
    IO.iodata_to_binary([
      Enum.map(inputs, &field_bytes(1, &1)),
      Enum.map(outputs, &field_bytes(2, &1)),
      field_bytes(4, op_type),
      Enum.map(attrs, &field_bytes(5, &1))
    ])
  end

  defp attr_int(name, value) do
    IO.iodata_to_binary([field_bytes(1, name), field_varint(3, value), field_varint(20, 2)])
  end

  defp attr_string(name, value) do
    IO.iodata_to_binary([field_bytes(1, name), field_bytes(4, value), field_varint(20, 3)])
  end

  defp attr_ints(name, values) do
    IO.iodata_to_binary([
      field_bytes(1, name),
      Enum.map(values, &field_varint(8, &1)),
      field_varint(20, 7)
    ])
  end

  defp tensor_proto(name, dims, data_type, raw_data) do
    IO.iodata_to_binary([
      Enum.map(dims, &field_varint(1, &1)),
      field_varint(2, data_type),
      field_bytes(8, name),
      field_bytes(9, raw_data)
    ])
  end

  defp value_info_proto(name, elem_type, dims) do
    dim_protos =
      Enum.map(dims, fn
        d when is_integer(d) -> field_bytes(1, field_varint(1, d))
        d when is_binary(d) -> field_bytes(1, field_bytes(2, d))
      end)

    tensor_type =
      IO.iodata_to_binary([
        field_varint(1, elem_type),
        field_bytes(2, IO.iodata_to_binary(dim_protos))
      ])

    type_proto = field_bytes(1, tensor_type)
    IO.iodata_to_binary([field_bytes(1, name), field_bytes(2, type_proto)])
  end

  defp field_varint(field_num, value) do
    [encode_varint(field_num <<< 3), encode_varint(value)]
  end

  defp field_bytes(field_num, data) do
    bin = IO.iodata_to_binary(data)
    [encode_varint(field_num <<< 3 ||| 2), encode_varint(byte_size(bin)), bin]
  end

  defp encode_varint(n) when n < 0 do
    encode_varint(band(n, 0xFFFFFFFFFFFFFFFF))
  end

  defp encode_varint(n) when n < 0x80, do: <<n>>

  defp encode_varint(n) do
    <<bor(band(n, 0x7F), 0x80), encode_varint(n >>> 7)::binary>>
  end
end
