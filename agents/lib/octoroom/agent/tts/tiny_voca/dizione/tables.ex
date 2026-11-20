defmodule Octoroom.Agent.TTS.TinyVoca.Dizione.Tables do
  @moduledoc false

  # Reads the hand-written dizione tables from `priv/tiny_voca/*.txt`.

  alias Octoroom.Agent.TTS.TinyVoca.Dizione.Convert

  @columns_re ~r/\t+| {2,}/
  @stress_classes MapSet.new(~w(u uf ur s ss si pf p))

  def data_dir, do: Application.app_dir(:octoroom_agents, "priv/tiny_voca")

  def rows(name) when is_binary(name) do
    text =
      if String.contains?(name, ["\n", "  ", "\t"]) do
        name
      else
        Path.join(data_dir(), name) |> File.read!()
      end

    text
    |> String.split(~r/\r?\n/)
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, number} ->
      trimmed = String.trim(line)

      if trimmed == "" or String.starts_with?(trimmed, "#") do
        []
      else
        cols = @columns_re |> Regex.split(trimmed) |> Enum.map(&String.trim/1)
        [{number, cols}]
      end
    end)
  end

  def function_words do
    Map.new(rows("function_words.txt"), fn {number, cols} ->
      case cols do
        [word, cls, form] ->
          validate_class!(cls, "function_words.txt", number)
          {word, {cls, Convert.from_text(form), nil}}

        [word, cls, form, final] ->
          validate_class!(cls, "function_words.txt", number)
          {word, {cls, Convert.from_text(form), Convert.from_text(final)}}

        _ ->
          raise ArgumentError, "function_words.txt line #{number}: bad row"
      end
    end)
  end

  def phrases do
    Map.new(rows("phrases.txt"), fn {number, cols} ->
      {words_str, cls, form_str, final_str} =
        case cols do
          [w, c, f] -> {w, c, f, nil}
          [w, c, f, fin] -> {w, c, f, fin}
          _ -> raise ArgumentError, "phrases.txt line #{number}: bad row"
        end

      validate_class!(cls, "phrases.txt", number)
      forms = form_str |> String.split("|") |> Enum.map(&Convert.from_text/1)
      key = String.split(words_str)
      final = if final_str, do: Convert.from_text(final_str)
      {key, {cls, forms, final}}
    end)
  end

  def pronunciations(source) do
    source
    |> entries()
    |> Enum.reduce(%{}, fn {_where, [lhs, rhs]}, acc ->
      case String.split(lhs) do
        [single] -> Map.put(acc, String.downcase(single), parse_pronunciation(rhs))
        _ -> acc
      end
    end)
  end

  def names(source) do
    source
    |> entries()
    |> Enum.reduce(%{}, fn {_where, [lhs, rhs]}, acc ->
      words = lhs |> String.downcase() |> String.split()

      if length(words) >= 2 do
        parts =
          rhs |> String.split("|") |> Enum.map(&(&1 |> String.trim() |> parse_pronunciation()))

        Map.put(acc, words, parts)
      else
        acc
      end
    end)
  end

  def mapping(name) do
    Map.new(rows(name), fn
      {_num, [k, v]} -> {k, v}
      {_num, [k]} -> {k, ""}
    end)
  end

  defp entries(map) when is_map(map), do: Enum.map(map, fn {k, v} -> {k, [k, v]} end)
  defp entries(source), do: rows(source)

  defp parse_pronunciation(text) do
    syms = String.split(text)
    if Convert.is_arpabet?(syms), do: {:arpabet, syms}, else: {:phones, Convert.from_text(text)}
  end

  defp validate_class!(cls, file, number) do
    unless MapSet.member?(@stress_classes, cls) do
      raise ArgumentError, "#{file} line #{number}: unknown stress class #{inspect(cls)}"
    end
  end
end
